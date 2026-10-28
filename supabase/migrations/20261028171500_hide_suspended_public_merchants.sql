-- Public visibility follows subscription state, not only nfc_profiles.active.
-- A cancelled or paused subscription is removed immediately, even before period end.
create or replace function nfc_private.merchant_public_visible(p_owner uuid)
returns boolean
language sql stable security definer
set search_path to ''
as $function$
select exists(
  select 1 from nfc_private.merchant_subscriptions s
  where s.owner_id=p_owner
    and s.status in ('trial','active')
    and s.billing_status not in ('cancelled','paused')
    and (
      s.comped_access
      or (
        s.status='trial'
        and s.period_ends_at >= (now() at time zone 'America/Argentina/Cordoba')::date
      )
      or (
        s.status='active' and (
          (s.billing_status in ('authorized','manual_paid')
             and s.period_ends_at >= (now() at time zone 'America/Argentina/Cordoba')::date)
          or
          (s.billing_provider='mercadopago'
             and s.billing_status in ('authorized','past_due')
             and s.period_ends_at+2 >= (now() at time zone 'America/Argentina/Cordoba')::date)
        )
      )
    )
)
$function$;
revoke all on function nfc_private.merchant_public_visible(uuid) from public;
grant execute on function nfc_private.merchant_public_visible(uuid) to anon, authenticated;

drop policy if exists nfc_profiles_read on public.nfc_profiles;
create policy nfc_profiles_read on public.nfc_profiles
for select to public
using(
  owner_id = (select auth.uid())
  or (active and nfc_private.merchant_public_visible(owner_id))
);

CREATE OR REPLACE FUNCTION nfc_private.nfc_card(p_profile uuid, p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.nfc_clients; p public.nfc_profiles;
begin
 select * into p from public.nfc_profiles where id=p_profile and active;
 if p.id is null then raise exception 'Perfil no disponible'; end if;
 if not nfc_private.merchant_public_visible(p.owner_id) then raise exception 'Perfil no disponible'; end if;
 select * into c from public.nfc_clients where profile_id=p_profile and card_token=p_token;
 if c.id is null then return null; end if;
 return jsonb_build_object('points',c.points,'visits',c.visits,'goal',p.goal,'reward',p.reward);
end $function$
;

CREATE OR REPLACE FUNCTION nfc_private.nfc_register_card_v3(p_profile uuid, p_token uuid, p_name text, p_phone text, p_address text, p_birth_day integer, p_birth_month integer, p_referral text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ref_id uuid;
begin
 if not exists(select 1 from public.nfc_profiles where id=p_profile and active and nfc_private.merchant_public_visible(owner_id)) then raise exception 'Perfil no disponible'; end if;
 if nullif(trim(coalesce(p_referral,'')),'') is not null then
   select id into ref_id from public.nfc_clients where profile_id=p_profile and referral_code=upper(trim(p_referral));
   if ref_id is null then raise exception 'Código de referido inválido'; end if;
 end if;
 insert into public.nfc_clients(profile_id,card_token,name,phone,address,birth_day,birth_month,referral_code,referred_by)
 values(p_profile,p_token,trim(p_name),p_phone,trim(coalesce(p_address,'')),p_birth_day,p_birth_month,
        upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),ref_id)
 on conflict(card_token) do nothing;
 return nfc_private.nfc_card(p_profile,p_token);
end $function$
;

CREATE OR REPLACE FUNCTION nfc_private.nfc_customer_extras(p_profile uuid, p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.nfc_clients; category text; result jsonb;
begin
 if not coalesce((select p.active and nfc_private.merchant_public_visible(p.owner_id) from public.nfc_profiles p where p.id=p_profile),false) then return null; end if;
 select * into c from public.nfc_clients where profile_id=p_profile and card_token=p_token;
 if c.id is null then return null; end if;
 category:=coalesce(c.manual_category,case when c.visits>=10 then 'vip' when c.visits>=3 then 'frequent' else 'new' end);
 select jsonb_build_object(
   'referral_code',c.referral_code,
   'referral_bonus_points',(select referral_bonus_points from public.nfc_profiles where id=p_profile),
   'referred_count',(select count(*) from public.nfc_clients r where r.referred_by=c.id),
   'rewarded_referrals',(select count(*) from public.nfc_clients r where r.referred_by=c.id and r.referral_rewarded_at is not null),
   'tiers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,'points_required',t.points_required,'reward',t.reward,'image_path',t.image_path
   ) order by t.points_required)
                     from public.nfc_reward_tiers t where t.profile_id=p_profile and t.active),'[]'::jsonb),
   'coupons',coalesce((select jsonb_agg(jsonb_build_object(
      'id',q.id,'title',q.title,'description',q.description,'code',q.code,'expires_at',q.expires_at,'audience',q.audience
    ) order by q.expires_at nulls last,q.created_at desc)
                       from public.nfc_coupons q where q.profile_id=p_profile and q.active
                       and (q.expires_at is null or q.expires_at>=current_date)
                       and (q.client_id is null or q.client_id=c.id)
                       and (q.audience='all' or q.audience=category or q.audience='birthday')),'[]'::jsonb)
 ) into result;
 return result;
end $function$
;
