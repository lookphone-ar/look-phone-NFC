-- Allow a merchant to correct the recorded amount of an existing visit.
-- Never inserts a new event or changes client points, visit counts or rewards.
create or replace function nfc_private.nfc_update_visit_amount(p_event uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
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
  if p_amount is null or p_amount < 0 or p_amount > 9999999999.99
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
$function$;
revoke all on function nfc_private.nfc_update_visit_amount(uuid,numeric) from public, anon, authenticated;
grant execute on function nfc_private.nfc_update_visit_amount(uuid,numeric) to authenticated;

create or replace function public.nfc_update_visit_amount(p_event uuid, p_amount numeric)
returns jsonb language sql security invoker set search_path = ''
as $function$
  select nfc_private.nfc_update_visit_amount(p_event,p_amount);
$function$;
revoke all on function public.nfc_update_visit_amount(uuid,numeric) from public, anon, authenticated;
grant execute on function public.nfc_update_visit_amount(uuid,numeric) to authenticated;
