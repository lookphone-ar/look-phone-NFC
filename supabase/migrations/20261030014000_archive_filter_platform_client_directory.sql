-- LOOK: excluir clientes retirados de los listados globales sin borrar ventas históricas.
-- Reutilizar íntegro el SQL de cada función, solo filtrando las filas archivadas.
do $$
declare v_name text; v_def text; v_changed text;
begin
 foreach v_name in array array['nfc_platform_client_directory','nfc_platform_client_groups','nfc_platform_business_clients'] loop
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname=v_name;
  if v_def is null then raise exception 'No se encontró la función: %',v_name; end if;
  v_changed:=replace(v_def,'from public.nfc_clients c','from (select * from public.nfc_clients where archived_at is null) c');
  v_changed:=replace(v_changed,'join public.nfc_clients c','join (select * from public.nfc_clients where archived_at is null) c');
  v_changed:=replace(v_changed,'from public.nfc_clients cx','from (select * from public.nfc_clients where archived_at is null) cx');
  if v_changed=v_def then raise exception 'No se encontró la consulta de clientes en %',v_name; end if;
  execute v_changed;
 end loop;
end $$;
