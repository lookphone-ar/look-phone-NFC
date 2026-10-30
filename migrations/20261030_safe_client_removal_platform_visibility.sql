-- LOOK: baja segura de clientes + ocultar comercios solo en panel de administración.
-- No modifica, suspende ni elimina ninguna cuenta o cliente existente.
alter table public.nfc_clients
  add column if not exists archived_at timestamptz;
create index if not exists nfc_clients_active_profile_idx
  on public.nfc_clients(profile_id, archived_at);

-- Solo backend de administración; no exponer esta tabla mediante Data API.
create table if not exists nfc_private.platform_hidden_accounts (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  hidden_at timestamptz not null default now(),
  hidden_by uuid references auth.users(id) on delete set null
);
alter table nfc_private.platform_hidden_accounts enable row level security;
revoke all on nfc_private.platform_hidden_accounts from public, anon, authenticated;

create or replace function public.nfc_platform_hidden_accounts()
returns jsonb language plpgsql stable security definer set search_path to ''
as $$
declare v_user uuid:=auth.uid();
begin
 if v_user is null or not exists(select 1 from nfc_private.platform_admins where user_id=v_user)
  then raise exception 'Solo un administrador de LOOK puede consultar comercios ocultos'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'owner_id',owner_id,'hidden_at',hidden_at
 ) order by hidden_at desc) from nfc_private.platform_hidden_accounts),'[]'::jsonb);
end $$;

create or replace function public.nfc_platform_set_hidden_account(p_owner uuid,p_hidden boolean)
returns jsonb language plpgsql security definer set search_path to ''
as $$
declare v_user uuid:=auth.uid(); v_hidden timestamptz;
begin
 if v_user is null or not exists(select 1 from nfc_private.platform_admins where user_id=v_user)
  then raise exception 'Solo un administrador de LOOK puede ocultar o recuperar comercios'; end if;
 if p_owner is null or not exists(select 1 from auth.users where id=p_owner)
  then raise exception 'No se encontró la cuenta del comercio'; end if;
 if p_hidden is null then raise exception 'Indicá la acción a realizar'; end if;
 if p_hidden and exists(select 1 from nfc_private.platform_admins where user_id=p_owner)
  then raise exception 'No se puede ocultar una cuenta administradora'; end if;
 if p_hidden then
  insert into nfc_private.platform_hidden_accounts(owner_id,hidden_at,hidden_by)
  values(p_owner,now(),v_user)
  on conflict(owner_id) do update set hidden_at=now(),hidden_by=excluded.hidden_by;
 else
  delete from nfc_private.platform_hidden_accounts where owner_id=p_owner;
 end if;
 select hidden_at into v_hidden from nfc_private.platform_hidden_accounts where owner_id=p_owner;
 return jsonb_build_object('owner_id',p_owner,'hidden',v_hidden is not null,'hidden_at',v_hidden);
end $$;

-- Nunca borra movimientos ni puntos de un cliente con historia.
-- Solo elimina de verdad una tarjeta sin ninguna relación/actividad registrada.
create or replace function public.nfc_manage_client(p_client uuid,p_restore boolean default false)
returns jsonb language plpgsql security definer set search_path to ''
as $$
declare v_user uuid:=auth.uid(); v_c public.nfc_clients%rowtype; v_owner uuid;
begin
 if v_user is null or p_client is null then raise exception 'Iniciá sesión y elegí un cliente'; end if;
 select c.*, p.owner_id into v_c,v_owner
 from public.nfc_clients c
 join public.nfc_profiles p on p.id=c.profile_id
 where c.id=p_client for update of c;
 if v_c.id is null or v_owner<>v_user then
  raise exception 'No tenés permiso para gestionar este cliente';
 end if;
 if coalesce(p_restore,false) then
  if v_c.archived_at is null then raise exception 'Este cliente no está eliminado'; end if;
  update public.nfc_clients set archived_at=null where id=p_client;
  return jsonb_build_object('action','restored','client_id',p_client);
 end if;
 if v_c.archived_at is not null then
  return jsonb_build_object('action','archived','client_id',p_client);
 end if;
 if not exists(select 1 from public.nfc_events where client_id=p_client)
   and not exists(select 1 from public.nfc_contact_events where client_id=p_client)
   and not exists(select 1 from public.nfc_coupons where client_id=p_client)
   and not exists(select 1 from public.nfc_coupon_redemptions where client_id=p_client)
   and not exists(select 1 from nfc_private.customer_privacy_requests where client_id=p_client)
   and not exists(select 1 from public.nfc_clients where referred_by=p_client)
 then
  delete from public.nfc_clients where id=p_client;
  return jsonb_build_object('action','deleted','client_id',p_client);
 end if;
 update public.nfc_clients set archived_at=now() where id=p_client;
 return jsonb_build_object('action','archived','client_id',p_client);
end $$;

-- Una tarjeta archivada ya no acredita ni canjea puntos aunque se tenga el enlace antiguo.
create or replace function nfc_private.reject_archived_client_event()
returns trigger language plpgsql security definer set search_path to ''
as $$
begin
 if exists(select 1 from public.nfc_clients where id=new.client_id and archived_at is not null)
  then raise exception 'Esta tarjeta fue eliminada del comercio. Reactivala antes de registrar compras.'; end if;
 return new;
end $$;
drop trigger if exists nfc_events_archived_client_guard on public.nfc_events;
create trigger nfc_events_archived_client_guard
 before insert on public.nfc_events
 for each row execute function nfc_private.reject_archived_client_event();

create or replace function nfc_private.nfc_card(p_profile uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path to ''
as $$
declare c public.nfc_clients; p public.nfc_profiles;
begin
 select * into p from public.nfc_profiles where id=p_profile and active;
 if p.id is null then raise exception 'Perfil no disponible'; end if;
 if not nfc_private.merchant_public_visible(p.owner_id) then raise exception 'Perfil no disponible'; end if;
 select * into c from public.nfc_clients
 where profile_id=p_profile and card_token=p_token and archived_at is null;
 if c.id is null then return null; end if;
 return jsonb_build_object('points',c.points,'visits',c.visits,'goal',p.goal,'reward',p.reward);
end $$;

create or replace function nfc_private.nfc_customer_extras(p_profile uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path to ''
as $$
declare c public.nfc_clients; category text; result jsonb;
begin
 if not coalesce((select p.active and nfc_private.merchant_public_visible(p.owner_id)
   from public.nfc_profiles p where p.id=p_profile),false) then return null; end if;
 select * into c from public.nfc_clients
 where profile_id=p_profile and card_token=p_token and archived_at is null;
 if c.id is null then return null; end if;
 category:=coalesce(c.manual_category,case when c.visits>=10 then 'vip'
   when c.visits>=3 then 'frequent' else 'new' end);
 select jsonb_build_object(
   'referral_code',c.referral_code,'referral_bonus_points',0,
   'referred_count',(select count(*) from public.nfc_clients r where r.referred_by=c.id),
   'rewarded_referrals',(select count(*) from public.nfc_clients r where r.referred_by=c.id and r.referral_rewarded_at is not null),
   'tiers',coalesce((select jsonb_agg(jsonb_build_object(
     'id',t.id,'points_required',t.points_required,'reward',t.reward,'image_path',t.image_path
   ) order by t.points_required) from public.nfc_reward_tiers t
      where t.profile_id=p_profile and t.active),'[]'::jsonb),
   'coupons',coalesce((select jsonb_agg(jsonb_build_object(
     'id',q.id,'title',q.title,'description',q.description,'code',q.code,
     'expires_at',q.expires_at,'audience',q.audience
   ) order by q.expires_at nulls last,q.created_at desc) from public.nfc_coupons q
      where q.profile_id=p_profile and q.active
      and (q.expires_at is null or q.expires_at>=current_date)
      and (q.client_id is null or q.client_id=c.id)
      and (q.audience='all' or q.audience=category or q.audience='birthday')),'[]'::jsonb)
 into result;
 return result;
end $$;

create or replace function public.nfc_staff_clients(p_search text default ''::text)
returns jsonb language plpgsql stable security definer set search_path to ''
as $$
declare v_owner uuid;v_profile public.nfc_profiles%rowtype;v_search text:=lower(trim(coalesce(p_search,'')));
begin
 select owner_id into v_owner from nfc_private.merchant_staff where user_id=auth.uid() and active limit 1;
 if v_owner is null or not nfc_private.staff_owner_allowed(v_owner) then raise exception 'Sin acceso al comercio'; end if;
 select * into v_profile from public.nfc_profiles where owner_id=v_owner and active order by created_at limit 1;
 if not found then raise exception 'Comercio pausado'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'name',z.name,'phone',z.phone,
  'points',z.points,'visits',z.visits,'goal',v_profile.goal,'reward',v_profile.reward))
 from (select id,name,phone,points,visits from public.nfc_clients
   where profile_id=v_profile.id and archived_at is null
   and (v_search='' or lower(name) like '%'||v_search||'%' or phone like '%'||v_search||'%')
   order by name asc limit 40) z),'[]'::jsonb);
end $$;

revoke all on function public.nfc_manage_client(uuid,boolean) from public,anon;
grant execute on function public.nfc_manage_client(uuid,boolean) to authenticated;
revoke all on function public.nfc_platform_hidden_accounts() from public,anon;
grant execute on function public.nfc_platform_hidden_accounts() to authenticated;
revoke all on function public.nfc_platform_set_hidden_account(uuid,boolean) from public,anon;
grant execute on function public.nfc_platform_set_hidden_account(uuid,boolean) to authenticated;
