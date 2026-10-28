-- Reward images belong to the merchant's own profile and are served publicly on its loyalty card.
alter table public.nfc_profiles add column if not exists reward_image_path text;
alter table public.nfc_reward_tiers add column if not exists image_path text;
do $$
begin
 if not exists (select 1 from pg_constraint where conname='nfc_profile_reward_image_owner') then
  alter table public.nfc_profiles add constraint nfc_profile_reward_image_owner
  check (reward_image_path is null or (reward_image_path ~ '^[a-f0-9-]{36}/[a-f0-9-]{36}\.(png|jpg|webp)$' and split_part(reward_image_path,'/',1)=id::text));
 end if;
 if not exists (select 1 from pg_constraint where conname='nfc_tier_reward_image_owner') then
  alter table public.nfc_reward_tiers add constraint nfc_tier_reward_image_owner
  check (image_path is null or (image_path ~ '^[a-f0-9-]{36}/[a-f0-9-]{36}\.(png|jpg|webp)$' and split_part(image_path,'/',1)=profile_id::text));
 end if;
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('merchant-rewards','merchant-rewards',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Owners upload reward photos" on storage.objects;
create policy "Owners upload reward photos" on storage.objects
for insert to authenticated
with check (
 bucket_id='merchant-rewards'
 and (storage.foldername(name))[1] is not null
 and exists(
  select 1 from public.nfc_profiles p
  where p.id::text=(storage.foldername(storage.objects.name))[1]
    and p.owner_id=(select auth.uid())
    and p.active
 )
 and (select nfc_private.current_account_enabled())
);

-- Existing card tokens retain their authorization rules. Image keys are returned only for the card's merchant.
create or replace function nfc_private.nfc_customer_extras(p_profile uuid,p_token uuid)
returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare c public.nfc_clients; category text; result jsonb;
begin
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
end $function$;
