-- ============================================================================
--  FARMS — migration 50
--  DELIVERY ADDRESSES, SHOPEE STYLE
--
--  • A buyer keeps an address book (Home, Work, …), one of them the default.
--  • At checkout the buyer picks where this order goes.
--  • The address is copied onto the order, so the farm always sees where THAT
--    order is going, even if the buyer later edits or deletes the saved address.
--
--  Run this once in the Supabase SQL Editor ("Run without RLS" if asked).
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. THE ADDRESS BOOK
-- ---------------------------------------------------------------------------
create table if not exists public.buyer_addresses (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles(id) on delete cascade,
  label          text not null default 'Home',
  recipient_name text not null,
  phone          text not null,
  province       text not null,
  city           text not null,
  barangay       text not null,
  purok_id       uuid references public.puroks(id) on delete set null,
  street         text not null,
  note           text not null default '',
  is_default     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint buyer_addresses_label_valid check (label in ('Home', 'Work', 'Other')),
  constraint buyer_addresses_text_sizes check (
    char_length(recipient_name) between 2 and 80
    and char_length(province)   between 2 and 80
    and char_length(city)       between 2 and 80
    and char_length(barangay)   between 2 and 80
    and char_length(street)     between 3 and 200
    and char_length(note)       <= 200
  )
);

create index if not exists buyer_addresses_profile_idx on public.buyer_addresses(profile_id);

-- Only one default per buyer.
create unique index if not exists buyer_addresses_one_default
  on public.buyer_addresses(profile_id) where is_default;

alter table public.buyer_addresses enable row level security;

-- A buyer can read their own addresses. All changes go through the functions
-- below, so the "one default" rule and the limits cannot be bypassed.
drop policy if exists buyer_addresses_read on public.buyer_addresses;
create policy buyer_addresses_read on public.buyer_addresses
  for select to authenticated
  using (public.is_mine(profile_id) or public.is_admin());


-- ---------------------------------------------------------------------------
-- 2. THE ADDRESS IS COPIED ONTO EACH ORDER
-- Old orders have none, so the columns are optional.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists ship_name    text,
  add column if not exists ship_phone   text,
  add column if not exists ship_address text,
  add column if not exists ship_note    text;


-- ---------------------------------------------------------------------------
-- 3. SAVE / DELETE / SET DEFAULT
-- ---------------------------------------------------------------------------
create or replace function public.clean_ph_mobile(p_raw text)
returns text language sql immutable as $$
  select case
    when regexp_replace(coalesce(p_raw, ''), '[\s()-]', '', 'g') ~ '^\+639[0-9]{9}$'
      then regexp_replace(p_raw, '[\s()-]', '', 'g')
    when regexp_replace(coalesce(p_raw, ''), '[\s()-]', '', 'g') ~ '^09[0-9]{9}$'
      then '+63' || substr(regexp_replace(p_raw, '[\s()-]', '', 'g'), 2)
    when regexp_replace(coalesce(p_raw, ''), '[\s()-]', '', 'g') ~ '^639[0-9]{9}$'
      then '+' || regexp_replace(p_raw, '[\s()-]', '', 'g')
    else null
  end
$$;

create or replace function public.save_buyer_address(
  p_id        uuid,
  p_label     text,
  p_name      text,
  p_phone     text,
  p_province  text,
  p_city      text,
  p_barangay  text,
  p_purok_id  uuid,
  p_street    text,
  p_note      text,
  p_default   boolean
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me      uuid := public.my_profile_id('buyer');
  v_phone   text := public.clean_ph_mobile(p_phone);
  v_label   text := coalesce(nullif(trim(p_label), ''), 'Home');
  v_count   int;
  v_id      uuid;
  v_default boolean := coalesce(p_default, false);
begin
  if v_me is null then
    raise exception 'Sign in as a buyer to save an address.';
  end if;
  if v_label not in ('Home', 'Work', 'Other') then
    raise exception 'Choose Home, Work or Other.';
  end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Enter the name of the person who will receive the order.';
  end if;
  if v_phone is null then
    raise exception 'Use a Philippine mobile number, like 09171234567.';
  end if;
  if char_length(trim(coalesce(p_province, ''))) < 2 then
    raise exception 'Enter the province.';
  end if;
  if char_length(trim(coalesce(p_city, ''))) < 2 then
    raise exception 'Enter the city or municipality.';
  end if;
  if char_length(trim(coalesce(p_barangay, ''))) < 2 then
    raise exception 'Enter the barangay.';
  end if;
  if char_length(trim(coalesce(p_street, ''))) < 3 then
    raise exception 'Enter the street, house number or a landmark so the farm can find you.';
  end if;
  if char_length(coalesce(p_note, '')) > 200 then
    raise exception 'Keep the delivery note under 200 characters.';
  end if;
  if p_purok_id is not null and not exists (select 1 from puroks where id = p_purok_id) then
    raise exception 'That purok does not exist.';
  end if;

  select count(*) into v_count from buyer_addresses where profile_id = v_me;

  if p_id is null then
    if v_count >= 10 then
      raise exception 'You can save up to 10 addresses. Delete one you no longer use.';
    end if;
    -- The first address is always the default.
    if v_count = 0 then v_default := true; end if;

    if v_default then
      update buyer_addresses set is_default = false where profile_id = v_me and is_default;
    end if;

    insert into buyer_addresses
      (profile_id, label, recipient_name, phone, province, city, barangay, purok_id,
       street, note, is_default)
    values
      (v_me, v_label, trim(p_name), v_phone, trim(p_province), trim(p_city), trim(p_barangay),
       p_purok_id, trim(p_street), trim(coalesce(p_note, '')), v_default)
    returning id into v_id;
  else
    if not exists (select 1 from buyer_addresses where id = p_id and profile_id = v_me) then
      raise exception 'That address was not found.';
    end if;

    -- Un-ticking "default" on the current default would leave none, so keep it.
    if not v_default and exists (
      select 1 from buyer_addresses where id = p_id and profile_id = v_me and is_default
    ) then
      v_default := true;
    end if;
    if v_default then
      update buyer_addresses set is_default = false
       where profile_id = v_me and is_default and id <> p_id;
    end if;

    update buyer_addresses
       set label = v_label, recipient_name = trim(p_name), phone = v_phone,
           province = trim(p_province), city = trim(p_city), barangay = trim(p_barangay),
           purok_id = p_purok_id, street = trim(p_street),
           note = trim(coalesce(p_note, '')), is_default = v_default, updated_at = now()
     where id = p_id and profile_id = v_me;
    v_id := p_id;
  end if;

  return v_id;
end $$;

create or replace function public.delete_buyer_address(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me      uuid := public.my_profile_id('buyer');
  v_was_def boolean;
begin
  if v_me is null then
    raise exception 'Sign in as a buyer to change your addresses.';
  end if;

  select is_default into v_was_def from buyer_addresses where id = p_id and profile_id = v_me;
  if not found then
    raise exception 'That address was not found.';
  end if;

  delete from buyer_addresses where id = p_id and profile_id = v_me;

  -- If the default was deleted, the newest remaining address takes its place.
  if v_was_def then
    update buyer_addresses set is_default = true
     where id = (select id from buyer_addresses where profile_id = v_me
                  order by created_at desc limit 1);
  end if;
end $$;

create or replace function public.set_default_buyer_address(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := public.my_profile_id('buyer');
begin
  if v_me is null then
    raise exception 'Sign in as a buyer to change your addresses.';
  end if;
  if not exists (select 1 from buyer_addresses where id = p_id and profile_id = v_me) then
    raise exception 'That address was not found.';
  end if;

  update buyer_addresses set is_default = false where profile_id = v_me and is_default and id <> p_id;
  update buyer_addresses set is_default = true  where id = p_id and profile_id = v_me;
end $$;


-- ---------------------------------------------------------------------------
-- 4. PLACING AN ORDER NOW NEEDS AN ADDRESS
-- The old three-argument version is dropped so a call can only reach this one.
-- ---------------------------------------------------------------------------
drop function if exists public.purchase_product(uuid, integer, text);

create or replace function public.purchase_product(
  p_product_id     uuid,
  p_quantity       int,
  p_payment_method text default null,
  p_address_id     uuid default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_product    products%rowtype;
  v_buyer      uuid := public.my_profile_id('buyer');
  v_qty        int  := floor(p_quantity)::int;
  v_total      numeric(12,2);
  v_order_id   uuid;
  v_method     text;
  v_farm       farms%rowtype;
  v_buyer_name text;
  v_available  int;
  v_addr       buyer_addresses%rowtype;
  v_purok      text;
  v_ship       text;
begin
  if v_buyer is null then
    raise exception 'Sign in as a buyer to place an order.';
  end if;
  if v_qty < 1 then
    raise exception 'Enter a quantity of at least 1.';
  end if;

  -- Where the order goes. It must be one of this buyer's own saved addresses.
  if p_address_id is null then
    raise exception 'Choose a delivery address for this order.';
  end if;
  select * into v_addr from buyer_addresses where id = p_address_id and profile_id = v_buyer;
  if not found then
    raise exception 'That delivery address was not found. Choose or add one.';
  end if;
  select name into v_purok from puroks where id = v_addr.purok_id;
  v_ship := concat_ws(', ', v_addr.street, v_purok, v_addr.barangay, v_addr.city, v_addr.province);

  select * into v_product from products where id = p_product_id for update;
  if not found then
    raise exception 'That listing is no longer available.';
  end if;

  v_available := greatest(v_product.quantity - v_product.reserved, 0);

  if v_available <= 0 or v_product.status = 'sold' then
    raise exception 'This product is out of stock.';
  end if;
  if v_qty > v_available then
    raise exception 'Only % left. Lower your quantity to continue.',
      public.unit_phrase(v_product.crop, v_available);
  end if;

  v_total := v_qty * v_product.price;

  select * into v_farm from farms where id = v_product.farm_id;
  select name into v_buyer_name from profiles where id = v_buyer;

  -- How the buyer will pay. It must be one the farm accepts for this product.
  v_method := lower(coalesce(nullif(trim(p_payment_method), ''),
                             case when v_product.pay_cash then 'cash' else 'gcash' end));
  if v_method not in ('cash', 'gcash') then
    raise exception 'Choose cash or GCash.';
  end if;
  if (v_method = 'cash' and not v_product.pay_cash)
     or (v_method = 'gcash' and not v_product.pay_gcash) then
    raise exception 'This farm does not accept % for this product.',
      case when v_method = 'cash' then 'cash' else 'GCash' end;
  end if;

  insert into orders (buyer_id, product_id, quantity, total_price, status, stage, payment_method,
                      ship_name, ship_phone, ship_address, ship_note)
  values (v_buyer, p_product_id, v_qty, v_total, 'pending', 'placed', v_method,
          v_addr.recipient_name, v_addr.phone, v_ship, nullif(v_addr.note, ''))
  returning id into v_order_id;

  insert into order_events (order_id, stage, note, changed_by)
  values (v_order_id, 'placed', 'Order placed by the buyer', v_buyer);

  update products
     set reserved = reserved + v_qty,
         status = case
                    when quantity - (reserved + v_qty) <= 0 then 'reserved'::product_status
                    else status
                  end
   where id = p_product_id;

  insert into notifications (user_id, message, type, link) values
    (v_farm.owner_id,
     coalesce(v_buyer_name,'A buyer') || ' ordered ' || public.unit_phrase(v_product.crop, v_qty) || ' of ' || v_product.variety
       || ' (pays by ' || case when v_method = 'gcash' then 'GCash' else 'cash' end || '), deliver to '
       || v_addr.barangay,
     'sale', '/owner/orders'),
    (v_buyer,
     'Order placed: ' || public.unit_phrase(v_product.crop, v_qty) || ' of ' || v_product.variety || ' from ' || coalesce(v_farm.name,'the farm'),
     'purchase', '/buyer/orders');

  return v_order_id;
end $$;


-- ---------------------------------------------------------------------------
-- 5. PERMISSIONS
-- ---------------------------------------------------------------------------
grant execute on function public.clean_ph_mobile(text) to authenticated;
grant execute on function public.save_buyer_address(uuid, text, text, text, text, text, text, uuid, text, text, boolean) to authenticated;
grant execute on function public.delete_buyer_address(uuid) to authenticated;
grant execute on function public.set_default_buyer_address(uuid) to authenticated;
grant execute on function public.purchase_product(uuid, integer, text, uuid) to authenticated;

notify pgrst, 'reload schema';
