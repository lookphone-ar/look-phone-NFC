alter table public.nfc_profiles
add column if not exists logo_scale integer not null default 85
check (logo_scale between 40 and 100);
