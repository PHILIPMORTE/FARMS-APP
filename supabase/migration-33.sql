-- ============================================================================
--  FARMS — MIGRATION 33
--  Puroks of Barangay Pagatban, with optional traced boundaries.
--  A purok can be chosen from a list, or worked out from a map pin once its
--  boundary has been drawn. Boundaries are stored as plain point lists, so no
--  mapping extension is needed.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

create table if not exists public.puroks (
  id         uuid primary key default gen_random_uuid(),
  number     int not null,
  name       text not null,
  barangay   text not null default 'Pagatban',
  city       text not null default 'Bayawan City',
  province   text not null default 'Negros Oriental',
  latitude   numeric(10,7),
  longitude  numeric(10,7),
  boundary   jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists puroks_number_key on public.puroks(barangay, number);

alter table public.puroks enable row level security;

drop policy if exists puroks_read on public.puroks;
create policy puroks_read on public.puroks for select to authenticated using (true);

drop policy if exists puroks_write on public.puroks;
create policy puroks_write on public.puroks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

insert into public.puroks (number, name)
select n, 'Purok ' || n from generate_series(1, 8) as n
on conflict (barangay, number) do nothing;

create or replace function public.point_in_boundary(
  p_lat numeric, p_lng numeric, p_boundary jsonb
)
returns boolean
language plpgsql immutable
as $$
declare
  n int; i int; j int;
  xi numeric; yi numeric; xj numeric; yj numeric;
  inside boolean := false;
begin
  if p_boundary is null or jsonb_typeof(p_boundary) <> 'array' then
    return false;
  end if;

  n := jsonb_array_length(p_boundary);
  if n < 3 then return false; end if;

  j := n - 1;
  for i in 0 .. n - 1 loop
    xi := (p_boundary -> i -> 0)::numeric;
    yi := (p_boundary -> i -> 1)::numeric;
    xj := (p_boundary -> j -> 0)::numeric;
    yj := (p_boundary -> j -> 1)::numeric;

    if ((yi > p_lat) <> (yj > p_lat))
       and (p_lng < (xj - xi) * (p_lat - yi) / nullif(yj - yi, 0) + xi) then
      inside := not inside;
    end if;

    j := i;
  end loop;

  return inside;
end $$;

grant execute on function public.point_in_boundary(numeric, numeric, jsonb) to authenticated;

create or replace function public.purok_at(p_lat numeric, p_lng numeric)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare v_row puroks%rowtype;
begin
  if p_lat is null or p_lng is null then return 'null'::json; end if;

  select * into v_row
    from puroks
   where boundary is not null
     and public.point_in_boundary(p_lat, p_lng, boundary)
   limit 1;

  if found then
    return json_build_object('id', v_row.id, 'number', v_row.number,
                             'name', v_row.name, 'exact', true);
  end if;

  select * into v_row
    from puroks
   where latitude is not null and longitude is not null
   order by public.distance_metres(p_lat, p_lng, latitude, longitude)
   limit 1;

  if found then
    return json_build_object('id', v_row.id, 'number', v_row.number,
      'name', v_row.name, 'exact', false,
      'distance_m', public.distance_metres(p_lat, p_lng, v_row.latitude, v_row.longitude));
  end if;

  return 'null'::json;
end $$;

grant execute on function public.purok_at(numeric, numeric) to authenticated;

alter table public.farms
  add column if not exists purok_id uuid references public.puroks(id) on delete set null;
alter table public.schedules
  add column if not exists purok_id uuid references public.puroks(id) on delete set null;
alter table public.job_posts
  add column if not exists purok_id uuid references public.puroks(id) on delete set null;
alter table public.profiles
  add column if not exists purok_id uuid references public.puroks(id) on delete set null;

create index if not exists farms_purok_idx on public.farms(purok_id);
create index if not exists schedules_purok_idx on public.schedules(purok_id);

notify pgrst, 'reload schema';
