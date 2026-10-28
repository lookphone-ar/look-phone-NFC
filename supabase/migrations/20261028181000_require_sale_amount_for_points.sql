-- Amount-required points, applied to owner, login-based staff and PIN employees.
-- Existing historical events and client balances are not changed.
-- Protect purchase points even when a caller bypasses the browser.
create or replace function nfc_private.require_purchase_sale_amount()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.kind='visit' and
      (new.sale_amount is null or new.sale_amount<=0 or new.sale_amount>9999999999.99
       or new.sale_amount<>round(new.sale_amount,2)) then
     raise exception 'Para sumar un punto debés ingresar un monto de venta válido, mayor a $0.';
  end if;
  if new.kind='referral' and new.delta>0 then
     raise exception 'Los puntos extra por referidos están deshabilitados: solo las compras con monto suman puntos.';
  end if;
  return new;
end
$$;
drop trigger if exists nfc_require_purchase_amount on public.nfc_events;
create trigger nfc_require_purchase_amount
before insert or update of kind,delta,sale_amount
on public.nfc_events for each row
execute function nfc_private.require_purchase_sale_amount();
revoke all on function nfc_private.require_purchase_sale_amount() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION nfc_private.nfc_record_event(p_client uuid, p_kind text, p_event uuid, p_sale_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.nfc_clients; p public.nfc_profiles; d integer; bonus_event uuid;
begin
 select * into c from public.nfc_clients where id=p_client for update;
 if c.id is null then raise exception 'Cliente no encontrado'; end if;
 select * into p from public.nfc_profiles where id=c.profile_id;
 if auth.uid() is null or p.owner_id<>auth.uid() then raise exception 'No autorizado'; end if;
 if p_kind not in ('visit','redeem') then raise exception 'Operación inválida'; end if;
 if p_kind='visit' and
   (p_sale_amount is null or p_sale_amount<=0 or p_sale_amount>9999999999.99 or p_sale_amount<>round(p_sale_amount,2))
   then raise exception 'Para sumar un punto es obligatorio ingresar el importe de la venta (mayor a $0).'; end if;
 if p_kind<>'visit' and p_sale_amount is not null then raise exception 'El importe solo corresponde a compras.'; end if;
 if exists(select 1 from public.nfc_events where id=p_event) then
  if not exists(select 1 from public.nfc_events where id=p_event and client_id=p_client and kind=p_kind) then raise exception 'Operación inválida'; end if;
  return jsonb_build_object('points',c.points,'visits',c.visits);
 end if;
 if not p.active then raise exception 'Perfil pausado'; end if;
 if p_kind='redeem' and c.points<p.goal then raise exception 'Todavía no tiene puntos suficientes'; end if;
 d:=case when p_kind='visit' then 1 else -p.goal end;
 insert into public.nfc_events(id,client_id,kind,delta,sale_amount) values(p_event,p_client,p_kind,d,case when p_kind='visit' then p_sale_amount else null end);
 update public.nfc_clients set points=points+d, visits=visits+case when p_kind='visit' then 1 else 0 end where id=p_client returning * into c;
 -- Referral bonuses are paused: points can only be earned through paid purchases.
 return jsonb_build_object('points',c.points,'visits',c.visits);
end $function$
;
-- Keep the legacy three-parameter RPC for redeem; visits without an amount are rejected.
create or replace function nfc_private.nfc_record_event(p_client uuid,p_kind text,p_event uuid)
returns jsonb language sql set search_path to ''
as $$ select nfc_private.nfc_record_event(p_client,p_kind,p_event,null::numeric) $$;

CREATE OR REPLACE FUNCTION public.nfc_staff_record(p_client uuid, p_kind text, p_event uuid, p_sale_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner uuid; c public.nfc_clients%rowtype;p public.nfc_profiles%rowtype;v_delta integer;
begin
 select owner_id into v_owner from nfc_private.merchant_staff where user_id=auth.uid() and active limit 1;
 if v_owner is null or not nfc_private.staff_owner_allowed(v_owner) then raise exception 'Sin acceso'; end if;
 if p_kind not in ('visit','redeem') then raise exception 'Operación inválida'; end if;
 if p_kind='visit' and
   (p_sale_amount is null or p_sale_amount<=0 or p_sale_amount>9999999999.99 or p_sale_amount<>round(p_sale_amount,2))
   then raise exception 'Para sumar un punto es obligatorio ingresar el importe de la venta (mayor a $0).'; end if;
 if p_kind<>'visit' and p_sale_amount is not null then raise exception 'El importe solo corresponde a compras.'; end if;
 select * into c from public.nfc_clients where id=p_client for update;
 if not found then raise exception 'Cliente no encontrado'; end if;
 select * into p from public.nfc_profiles where id=c.profile_id;
 if p.owner_id<>v_owner or not p.active then raise exception 'Perfil inválido'; end if;
 if exists(select 1 from public.nfc_events where id=p_event) then
   if not exists(select 1 from public.nfc_events where id=p_event and client_id=p_client and kind=p_kind and staff_user_id=auth.uid()) then
      raise exception 'Operación duplicada o ajena'; end if;
   return jsonb_build_object('points',c.points,'visits',c.visits);
 end if;
 if p_kind='visit' and exists(select 1 from public.nfc_events where client_id=p_client and kind='visit' and staff_user_id=auth.uid() and created_at>now()-interval '15 seconds') then
    raise exception 'Esperá unos segundos antes de registrar otra compra'; end if;
 if p_kind='redeem' and c.points<p.goal then raise exception 'Puntos insuficientes'; end if;
 v_delta:=case when p_kind='visit' then 1 else -p.goal end;
 insert into public.nfc_events(id,client_id,kind,delta,sale_amount,staff_user_id)
 values(p_event,p_client,p_kind,v_delta,case when p_kind='visit' then p_sale_amount else null end,auth.uid());
 update public.nfc_clients set points=points+v_delta,visits=visits+case when p_kind='visit' then 1 else 0 end
   where id=p_client returning * into c;
 -- Referral bonuses are paused: points can only be earned through paid purchases.
 return jsonb_build_object('points',c.points,'visits',c.visits);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.nfc_employee_record(p_employee uuid, p_client uuid, p_kind text, p_event uuid, p_sale_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.nfc_employee_profiles%rowtype; c public.nfc_clients%rowtype;
 p public.nfc_profiles%rowtype;v_delta integer;
begin
 if current_setting('request.jwt.claim.role',true) <> 'service_role' then raise exception 'Sin permiso'; end if;
 select * into s from public.nfc_employee_profiles where id=p_employee and active;
 if not found or not nfc_private.staff_owner_allowed(s.owner_id) then raise exception 'Empleado sin acceso'; end if;
 select * into c from public.nfc_clients where id=p_client for update;
 if not found then raise exception 'Cliente no encontrado'; end if;
 select * into p from public.nfc_profiles where id=c.profile_id;
 if p.id<>s.profile_id or p.owner_id<>s.owner_id or not p.active then raise exception 'Cliente de otro comercio'; end if;
 if p_kind not in ('visit','redeem') then raise exception 'Operación no permitida'; end if;
 if p_kind='visit' and
   (p_sale_amount is null or p_sale_amount<=0 or p_sale_amount>9999999999.99 or p_sale_amount<>round(p_sale_amount,2))
   then raise exception 'Para sumar un punto es obligatorio ingresar el importe de la venta (mayor a $0).'; end if;
 if p_kind<>'visit' and p_sale_amount is not null then raise exception 'El importe solo corresponde a compras.'; end if;
 if exists(select 1 from public.nfc_events where id=p_event) then
  if not exists(select 1 from public.nfc_events where id=p_event and client_id=p_client and kind=p_kind and employee_profile_id=p_employee)
  then raise exception 'Identificador de operación ajeno'; end if;
  return jsonb_build_object('points',c.points,'visits',c.visits);
 end if;
 if p_kind='visit' and exists(select 1 from public.nfc_events where client_id=p_client and kind='visit'
     and employee_profile_id=p_employee and created_at>now()-interval '15 seconds') then
     raise exception 'Esperá unos segundos para sumar otro punto'; end if;
 if p_kind='redeem' and c.points<p.goal then raise exception 'Puntos insuficientes'; end if;
 v_delta:=case when p_kind='visit' then 1 else -p.goal end;
 insert into public.nfc_events(id,client_id,kind,delta,sale_amount,employee_profile_id)
 values(p_event,p_client,p_kind,v_delta,case when p_kind='visit' then p_sale_amount else null end,p_employee);
 update public.nfc_clients
 set points=points+v_delta,visits=visits+case when p_kind='visit' then 1 else 0 end
 where id=p_client returning * into c;
 -- Referral bonuses paused under purchase-amount-only policy.
 return jsonb_build_object('points',c.points,'visits',c.visits);
end;
$function$
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
   'referral_bonus_points',0,
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
CREATE OR REPLACE FUNCTION nfc_private.nfc_update_visit_amount(p_event uuid, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_client uuid;
  v_kind text;
  v_owner uuid;
  v_active boolean;
  v_amount numeric;
begin
  if (select auth.uid()) is null then
    raise exception 'Iniciá sesión para modificar una compra' using errcode='42501';
  end if;
  if not nfc_private.current_account_enabled() then
    raise exception 'La cuenta no tiene acceso habilitado' using errcode='42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99
     or p_amount <> round(p_amount, 2) then
    raise exception 'Ingresá un monto válido con hasta dos decimales';
  end if;
  select e.client_id, e.kind, p.owner_id, p.active
    into v_client, v_kind, v_owner, v_active
    from public.nfc_events e
    join public.nfc_clients c on c.id=e.client_id
    join public.nfc_profiles p on p.id=c.profile_id
   where e.id=p_event
   for update of e;
  if not found then raise exception 'Movimiento no encontrado'; end if;
  if v_owner is distinct from (select auth.uid()) then
    raise exception 'No tenés permiso para modificar esta compra' using errcode='42501';
  end if;
  if v_kind <> 'visit' then
    raise exception 'Solo se puede corregir el importe de una compra';
  end if;
  if not v_active then
    raise exception 'El comercio está pausado';
  end if;

  update public.nfc_events
     set sale_amount=p_amount
   where id=p_event
   returning sale_amount into v_amount;
  return jsonb_build_object('id',p_event,'client_id',v_client,'sale_amount',v_amount);
end
$function$
;
notify pgrst, 'reload schema';
