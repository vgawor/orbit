-- Orbit Pro: accounts, subscriptions, bot ownership, usage and phone approvals.
-- Clients (the Mac app and the phone web app) only ever see their own rows. Everything that
-- touches money or Orbit's API keys happens in Edge Functions with the service role.

-- One row per account, made when someone signs up.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  plan text not null default 'free' check (plan in ('free', 'pro')),
  subscription_status text,
  paddle_customer_id text unique,
  paddle_subscription_id text unique,
  current_period_end timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
create policy "Read your own profile" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Which cloud agents, deployments, sessions and OpenAI responses belong to whom. The proxies
-- check this on every call, so one Pro user can never reach another's bots.
create table public.resources (
  remote_id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('agent', 'deployment', 'session', 'response')),
  created_at timestamptz not null default now()
);
create index resources_user on public.resources (user_id, kind);
alter table public.resources enable row level security;   -- service role only

-- What each run cost (US cents), for the fair-use limit and the usage shown in the app.
create table public.usage (
  run_id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('claude', 'chatgpt')),
  cost_cents integer not null default 0,
  month date not null default date_trunc('month', now())::date,
  updated_at timestamptz not null default now()
);
create index usage_user_month on public.usage (user_id, month);
alter table public.usage enable row level security;
create policy "Read your own usage" on public.usage
  for select to authenticated using ((select auth.uid()) = user_id);

-- Orbit-wide settings the functions keep (the shared cloud sandboxes).
create table public.config (
  key text primary key,
  value text not null
);
alter table public.config enable row level security;   -- service role only

-- Approvals waiting on the Mac, copied here so the phone can show them and answer.
create table public.approvals (
  user_id uuid not null references auth.users (id) on delete cascade,
  id text not null,
  bot_name text not null,
  bot_color text,
  title text not null,
  action text not null,
  reason text,
  fields jsonb not null default '[]',
  status text not null default 'pending' check (status in ('pending', 'decided', 'gone')),
  decision jsonb,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  primary key (user_id, id)
);
alter table public.approvals enable row level security;
create policy "Read your own approvals" on public.approvals
  for select to authenticated using ((select auth.uid()) = user_id);
-- The phone answers: only pending ones, only to "decided".
create policy "Answer your own approvals" on public.approvals
  for update to authenticated
  using ((select auth.uid()) = user_id and status = 'pending')
  with check ((select auth.uid()) = user_id and status = 'decided');

-- Phones that get a push notification when a bot needs an OK.
create table public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index push_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
create policy "Add your own phone" on public.push_subscriptions
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "See your own phones" on public.push_subscriptions
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Remove your own phone" on public.push_subscriptions
  for delete to authenticated using ((select auth.uid()) = user_id);

-- This month's spend for one user, in cents.
create function public.month_spend(uid uuid) returns integer
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(cost_cents), 0)::integer from public.usage
  where user_id = uid and month = date_trunc('month', now())::date;
$$;
revoke execute on function public.month_spend(uuid) from public, anon, authenticated;
