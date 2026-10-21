-- =====================================================================
-- musedtic  ·  database schema v0.1  (Supabase / PostgreSQL 15+)
-- Principle: privacy is enforced HERE, in the database, by Row Level
-- Security. The app can have bugs; the database still refuses to leak.
-- Run this whole file once in the Supabase SQL editor.
-- =====================================================================


-- ---------- 1. people ------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text not null,
  display_name  text not null default '',
  bio           text not null default '' check (char_length(bio) <= 280),
  avatar_url    text,
  theme         jsonb not null default '{"mode":"light","accent":"musedtic","texture":"plain"}',
  age_confirmed boolean not null default false,
  terms_version text, terms_accepted_at timestamptz,        -- the EULA / community rules they agreed to
  suspended_until timestamptz,                              -- set only by moderators (service role)
  ai_enabled boolean not null default false,                -- AI features are OFF until the person turns them on
  ai_journal_consent boolean not null default false,        -- journal text may be sent to an AI model ONLY if this is true
  created_at    timestamptz not null default now(),
  constraint username_format check (username ~ '^[a-z0-9_.]{3,24}$')
);
create unique index profiles_username_key on public.profiles (lower(username));

create table public.connections (            -- a request, then a "mutual" once accepted
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','accepted')),
  created_at   timestamptz not null default now(),
  check (requester_id <> addressee_id)
);
create unique index connections_pair_key on public.connections (least(requester_id, addressee_id), greatest(requester_id, addressee_id));

create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- ---------- 2. circles (small private groups -> communities) ---------
create table public.circles (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  kind       text not null default 'friends' check (kind in ('friends','family','book_club','music','writing','creative','film','wellness','cooking','other')),
  privacy    text not null default 'private' check (privacy in ('private','request','public')),
  about      text not null default '',
  current_item jsonb,                         -- what the circle is reading / listening to right now
  created_at timestamptz not null default now()
);
create table public.circle_members (
  circle_id uuid not null references public.circles(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  role      text not null default 'member' check (role in ('owner','mod','member')),
  status    text not null default 'active' check (status in ('active','requested')),
  joined_at timestamptz not null default now(),
  primary key (circle_id, user_id)
);

-- ---------- 3. the Wall ----------------------------------------------
create table public.posts (
  id         uuid primary key default gen_random_uuid(),
  author_id  uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('thought','photo','video','music','book','writing','recipe','card','poll')),
  body       text not null default '' check (char_length(body) <= 5000),
  media      jsonb not null default '[]',
  meta       jsonb not null default '{}',
  visibility text not null default 'private' check (visibility in ('private','mutuals','selected','circle','public')),
  circle_id  uuid references public.circles(id) on delete cascade,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  moderation_status text not null default 'ok' check (moderation_status in ('ok','held','removed')),
  check ((visibility = 'circle') = (circle_id is not null))
);
create index posts_author_idx on public.posts (author_id, created_at desc);
create table public.post_audience (post_id uuid not null references public.posts(id) on delete cascade, user_id uuid not null references public.profiles(id) on delete cascade, primary key (post_id, user_id));
create table public.reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind    text not null default 'love' check (kind in ('love','funny','appreciate','inspired','relatable')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  parent_id uuid references public.comments(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  moderation_status text not null default 'ok' check (moderation_status in ('ok','held','removed')),
  created_at timestamptz not null default now()
);
create table public.saves (user_id uuid not null references public.profiles(id) on delete cascade, post_id uuid not null references public.posts(id) on delete cascade, created_at timestamptz not null default now(), primary key (user_id, post_id));

-- "Listen Along": a short-lived status, never auto-public, always expires
create table public.listening (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  track      jsonb not null,                  -- {title, artist, source_url, links:{spotify:..,apple:..}}
  visibility text not null default 'nobody' check (visibility in ('nobody','mutuals')),
  started_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes'
);

-- ---------- 4. chats --------------------------------------------------
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('dm','group','family')),
  title text,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  primary key (conversation_id, user_id)
);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'text' check (kind in ('text','photo','song','card','game','book')),
  body text not null default '' check (char_length(body) <= 4000),
  meta jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index messages_conv_idx on public.messages (conversation_id, created_at);

-- ---------- 5. my world: journals, library, recipes -------------------
create table public.journals (               -- one row per journal a person keeps
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('personal','photo','junk','sticker','book','recipe','music','travel','movies','ideas','wellness','memories')),
  title text not null default '',
  created_at timestamptz not null default now()
);
create table public.journal_entries (        -- private by default; sharing creates a separate post
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.journals(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  entry_date date not null default current_date,
  mood_score smallint check (mood_score between 1 and 5),      -- Mood Flow: the person's own choice
  tags text[] not null default '{}',                           -- "what shaped today"
  moment_label text,                                           -- a big moment shown on the line
  moment_score smallint check (moment_score in (-2,-1,1,2)),
  content jsonb not null default '{}',                         -- text, photos, junk-journal layout, etc.
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index journal_entries_day_idx on public.journal_entries (owner_id, entry_date);
create table public.library_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'book' check (kind in ('book','film','series','podcast','album','article')),
  title text not null, creator text not null default '', cover_url text, link_url text,
  status text not null default 'want' check (status in ('want','current','done')),
  progress smallint not null default 0 check (progress between 0 and 100),
  metadata jsonb not null default '{}', created_at timestamptz not null default now()
);
create table public.recipes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  title text not null, kind text not null default 'food' check (kind in ('food','bake','drink')),
  ingredients jsonb not null default '[]', method text not null default '', notes text not null default '',
  photo_url text, made_count int not null default 0,
  nutrition jsonb,                              -- always labelled an ESTIMATE in the app
  source jsonb not null default '{}', created_at timestamptz not null default now()
);

-- ---------- 6. cards & invitations -----------------------------------
create table public.cards (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  occasion text not null check (occasion in ('birthday','graduation','wedding','just_because','valentines','holiday','thank_you','congratulations','thinking_of_you','get_well','sorry','new_chapter','new_baby','bon_voyage','sympathy','appreciation')),
  design text not null default 'handwritten',
  front_text text not null default '', note text not null check (char_length(note) between 1 and 2000),
  ai_assisted boolean not null default false,
  opened_at timestamptz, saved boolean not null default false,
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null default 'other', design text not null default 'minimal',
  title text not null, starts_at timestamptz, place text not null default '', note text not null default '',
  created_at timestamptz not null default now()
);
create table public.invitation_guests (
  invitation_id uuid not null references public.invitations(id) on delete cascade,
  guest_id uuid not null references public.profiles(id) on delete cascade,
  rsvp text not null default 'pending' check (rsvp in ('pending','yes','maybe','no')),
  responded_at timestamptz,
  primary key (invitation_id, guest_id)
);

-- ---------- 7. play ---------------------------------------------------
create table public.game_rooms (
  id uuid primary key default gen_random_uuid(),
  kind text not null, host_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'lobby' check (status in ('lobby','playing','finished')),
  settings jsonb not null default '{}', state jsonb not null default '{}', created_at timestamptz not null default now()
);
create table public.game_players (
  room_id uuid not null references public.game_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  score int not null default 0, primary key (room_id, user_id)
);

-- ---------- 8. notifications & safety --------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  kind text not null, payload jsonb not null default '{}',
  read_at timestamptz, created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create table public.notification_prefs (user_id uuid not null references public.profiles(id) on delete cascade, kind text not null, enabled boolean not null default true, primary key (user_id, kind));
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,   -- a report outlives the reporter's account, anonymised
  target_type text not null check (target_type in ('post','comment','message','profile','circle','card')),
  target_id uuid not null, reason text not null, details text not null default '',
  status text not null default 'open' check (status in ('open','reviewing','actioned','dismissed')),
  created_at timestamptz not null default now()
);

create table public.banned_terms (term text primary key);                      -- managed by moderators only
create table public.moderation_queue (                                            -- what the review team works through
  id uuid primary key default gen_random_uuid(), target_type text not null, target_id uuid not null,
  reason text not null, status text not null default 'open' check (status in ('open','actioned','dismissed')), created_at timestamptz not null default now());
create table public.ai_usage (user_id uuid not null references public.profiles(id) on delete cascade, day date not null default current_date, calls int not null default 0, primary key (user_id, day));

-- =====================================================================
-- helper functions (SECURITY DEFINER so they can look across rows safely)
-- =====================================================================
create or replace function public.is_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)) $$;

create or replace function public.is_mutual(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select a <> b and not is_blocked(a, b) and exists (
    select 1 from connections c where c.status = 'accepted'
      and ((c.requester_id = a and c.addressee_id = b) or (c.requester_id = b and c.addressee_id = a))) $$;

create or replace function public.is_circle_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from circle_members m where m.circle_id = cid and m.user_id = auth.uid() and m.status = 'active') $$;

create or replace function public.is_circle_mod(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from circle_members m where m.circle_id = cid and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','mod')) $$;

create or replace function public.is_conv_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_members m where m.conversation_id = cid and m.user_id = auth.uid()) $$;

create or replace function public.can_message(cid uuid) returns boolean   -- members only; a DM stops if either side blocks
language sql stable security definer set search_path = public as $$
  select is_conv_member(cid) and not exists (
    select 1 from conversations c join conversation_members o on o.conversation_id = c.id and o.user_id <> auth.uid()
    where c.id = cid and c.kind = 'dm' and is_blocked(auth.uid(), o.user_id)) $$;

create or replace function public.can_see_post(p public.posts) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and p.deleted_at is null and (
    p.author_id = auth.uid()
    or (p.moderation_status = 'ok' and not is_blocked(p.author_id, auth.uid()) and (
         p.visibility = 'public'
      or (p.visibility = 'mutuals'  and is_mutual(p.author_id, auth.uid()))
      or (p.visibility = 'selected' and exists (select 1 from post_audience a where a.post_id = p.id and a.user_id = auth.uid()))
      or (p.visibility = 'circle'   and is_circle_member(p.circle_id)))))  $$;

create or replace function public.can_see_post_id(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from posts p where p.id = pid and can_see_post(p)) $$;


create or replace function public.is_host(iid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from invitations where id = iid and host_id = auth.uid()) $$;
create or replace function public.is_invited(iid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from invitation_guests where invitation_id = iid and guest_id = auth.uid()) $$;
create or replace function public.is_room_host(rid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from game_rooms where id = rid and host_id = auth.uid()) $$;
create or replace function public.is_room_player(rid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from game_players where room_id = rid and user_id = auth.uid()) $$;
create or replace function public.is_post_author(pid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from posts where id = pid and author_id = auth.uid()) $$;

create or replace function public.notify(target uuid, actor uuid, k text, pl jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if target is null or target = actor then return; end if;
  if exists (select 1 from notification_prefs where user_id = target and kind = k and enabled = false) then return; end if;
  insert into notifications (user_id, actor_id, kind, payload) values (target, actor, k, pl);
end $$;

-- ---------- new account -> profile ----------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username, display_name, age_confirmed)
  values (new.id, lower(coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8))),
          coalesce(new.raw_user_meta_data->>'display_name', ''), coalesce((new.raw_user_meta_data->>'age_confirmed')::boolean, false));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.username_available(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(p_username) ~ '^[a-z0-9_.]{3,24}$' and not exists (select 1 from profiles where lower(username) = lower(p_username)) $$;

create or replace function public.is_suspended(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select suspended_until > now() from profiles where id = uid), false) $$;

-- objectionable-content filter: a match HOLDS the item for review (the author still sees it) instead of publishing it
create or replace function public.trg_filter() returns trigger language plpgsql security definer set search_path = public as $$
declare t text := tg_argv[0];
begin
  if exists (select 1 from banned_terms b where position(lower(b.term) in lower(new.body)) > 0) then
    new.moderation_status := 'held';
    insert into moderation_queue (target_type, target_id, reason) values (t, new.id, 'matched the automatic filter');
  end if;
  return new;
end $$;
create trigger filter_posts    before insert or update of body on public.posts    for each row execute function public.trg_filter('post');
create trigger filter_comments before insert or update of body on public.comments for each row execute function public.trg_filter('comment');

-- a person's own copy of everything (privacy rights; also what the store disclosures promise)
create or replace function public.export_my_data() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  return jsonb_build_object(
    'profile',  (select to_jsonb(p) from profiles p where p.id = me),
    'posts',    coalesce((select jsonb_agg(to_jsonb(x)) from posts x where x.author_id = me), '[]'),
    'comments', coalesce((select jsonb_agg(to_jsonb(x)) from comments x where x.author_id = me), '[]'),
    'journals', coalesce((select jsonb_agg(to_jsonb(x)) from journals x where x.owner_id = me), '[]'),
    'journal_entries', coalesce((select jsonb_agg(to_jsonb(x)) from journal_entries x where x.owner_id = me), '[]'),
    'library',  coalesce((select jsonb_agg(to_jsonb(x)) from library_items x where x.owner_id = me), '[]'),
    'recipes',  coalesce((select jsonb_agg(to_jsonb(x)) from recipes x where x.owner_id = me), '[]'),
    'cards_sent',     coalesce((select jsonb_agg(to_jsonb(x)) from cards x where x.sender_id = me), '[]'),
    'cards_received', coalesce((select jsonb_agg(to_jsonb(x)) from cards x where x.recipient_id = me), '[]'),
    'messages', coalesce((select jsonb_agg(to_jsonb(x)) from messages x where x.sender_id = me), '[]'));
end $$;

-- in-app account deletion (required by both stores). Cascades through every table above.
-- NOTE for the app: also delete the person's files from Storage in the same flow.
create or replace function public.delete_my_account() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- AI guard: nothing runs unless the person switched AI on, and each person has a daily allowance
create or replace function public.ai_consume(p_limit int) returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not coalesce((select ai_enabled from profiles where id = auth.uid()), false) then return false; end if;
  insert into ai_usage (user_id, day, calls) values (auth.uid(), current_date, 1)
    on conflict (user_id, day) do update set calls = ai_usage.calls + 1 returning calls into n;
  return n <= p_limit;
end $$;

-- =====================================================================
-- actions people take (RPCs): each one checks the rules itself
-- =====================================================================
create or replace function public.send_connection_request(p_username text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); target uuid; cid uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  select id into target from profiles where lower(username) = lower(p_username);
  if target is null then raise exception 'no such user'; end if;
  if target = me then raise exception 'that is you'; end if;
  if is_blocked(me, target) then raise exception 'not available'; end if;
  if exists (select 1 from connections where least(requester_id, addressee_id) = least(me, target) and greatest(requester_id, addressee_id) = greatest(me, target)) then raise exception 'already connected or pending'; end if;
  insert into connections (requester_id, addressee_id) values (me, target) returning id into cid;
  perform notify(target, me, 'connection_request', jsonb_build_object('connection_id', cid));
  return cid;
end $$;

create or replace function public.respond_connection(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare c connections;
begin
  select * into c from connections where id = p_id and addressee_id = auth.uid() and status = 'pending';
  if not found then raise exception 'no such request'; end if;
  if p_accept then
    update connections set status = 'accepted' where id = p_id;
    perform notify(c.requester_id, auth.uid(), 'connection_accepted', jsonb_build_object('connection_id', p_id));
  else delete from connections where id = p_id; end if;
end $$;

create or replace function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_user = auth.uid() then raise exception 'that is you'; end if;
  insert into blocks (blocker_id, blocked_id) values (auth.uid(), p_user) on conflict do nothing;
  delete from connections where least(requester_id, addressee_id) = least(auth.uid(), p_user) and greatest(requester_id, addressee_id) = greatest(auth.uid(), p_user);
end $$;

create or replace function public.start_dm(p_user uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cid uuid;
begin
  if not is_mutual(me, p_user) then raise exception 'you can message mutuals only'; end if;
  select c.id into cid from conversations c
    where c.kind = 'dm' and exists (select 1 from conversation_members m where m.conversation_id = c.id and m.user_id = me)
                         and exists (select 1 from conversation_members m where m.conversation_id = c.id and m.user_id = p_user);
  if cid is not null then return cid; end if;
  insert into conversations (kind, created_by) values ('dm', me) returning id into cid;
  insert into conversation_members (conversation_id, user_id, role) values (cid, me, 'owner'), (cid, p_user, 'member');
  return cid;
end $$;

create or replace function public.create_group(p_title text, p_kind text, p_members uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cid uuid; m uuid;
begin
  if p_kind not in ('group','family') then raise exception 'bad kind'; end if;
  foreach m in array p_members loop
    if not is_mutual(me, m) then raise exception 'every member must be your mutual'; end if;
  end loop;
  insert into conversations (kind, title, created_by) values (p_kind, p_title, me) returning id into cid;
  insert into conversation_members (conversation_id, user_id, role) values (cid, me, 'owner');
  insert into conversation_members (conversation_id, user_id) select distinct cid, x from unnest(p_members) x where x <> me;
  return cid;
end $$;

create or replace function public.send_card(p_recipient uuid, p_occasion text, p_design text, p_front text, p_note text, p_ai boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cid uuid;
begin
  if not is_mutual(me, p_recipient) then raise exception 'cards go to mutuals'; end if;
  insert into cards (sender_id, recipient_id, occasion, design, front_text, note, ai_assisted)
    values (me, p_recipient, p_occasion, p_design, coalesce(p_front,''), p_note, coalesce(p_ai,false)) returning id into cid;
  perform notify(p_recipient, me, 'card_received', jsonb_build_object('card_id', cid, 'occasion', p_occasion));
  return cid;
end $$;

create or replace function public.invite_guests(p_invitation uuid, p_guests uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g uuid;
begin
  if not exists (select 1 from invitations where id = p_invitation and host_id = me) then raise exception 'not your invitation'; end if;
  foreach g in array p_guests loop
    if not is_mutual(me, g) then raise exception 'guests must be your mutuals'; end if;
    insert into invitation_guests (invitation_id, guest_id) values (p_invitation, g) on conflict do nothing;
    perform notify(g, me, 'invitation_received', jsonb_build_object('invitation_id', p_invitation));
  end loop;
end $$;

create or replace function public.rsvp(p_invitation uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare host uuid;
begin
  if p_status not in ('yes','maybe','no') then raise exception 'bad status'; end if;
  update invitation_guests set rsvp = p_status, responded_at = now() where invitation_id = p_invitation and guest_id = auth.uid();
  if not found then raise exception 'you are not on this guest list'; end if;
  select host_id into host from invitations where id = p_invitation;
  perform notify(host, auth.uid(), 'rsvp', jsonb_build_object('invitation_id', p_invitation, 'rsvp', p_status));
end $$;

create or replace function public.set_listening(p_track jsonb, p_visibility text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into listening (user_id, track, visibility, started_at, expires_at) values (auth.uid(), p_track, p_visibility, now(), now() + interval '15 minutes')
  on conflict (user_id) do update set track = excluded.track, visibility = excluded.visibility, started_at = now(), expires_at = now() + interval '15 minutes';
end $$;

-- ---------- notification triggers ------------------------------------
create or replace function public.trg_reaction() returns trigger language plpgsql security definer set search_path = public as $$
begin perform notify((select author_id from posts where id = new.post_id), new.user_id, 'reaction', jsonb_build_object('post_id', new.post_id, 'kind', new.kind)); return new; end $$;
create trigger on_reaction after insert on public.reactions for each row execute function public.trg_reaction();
create or replace function public.trg_comment() returns trigger language plpgsql security definer set search_path = public as $$
begin perform notify((select author_id from posts where id = new.post_id), new.author_id, 'comment', jsonb_build_object('post_id', new.post_id, 'comment_id', new.id)); return new; end $$;
create trigger on_comment after insert on public.comments for each row execute function public.trg_comment();

-- =====================================================================
-- ROW LEVEL SECURITY: nothing is readable unless a rule below allows it
-- =====================================================================
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop; end $$;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon;
grant execute on function public.username_available(text) to anon;

-- profiles: anyone signed in can find people; you edit only yourself
create policy profiles_read   on public.profiles for select to authenticated using (not is_blocked(id, auth.uid()) or id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;      -- people can edit their own profile, but never their suspension
grant  update (username, display_name, bio, avatar_url, theme, age_confirmed, terms_version, terms_accepted_at, ai_enabled, ai_journal_consent) on public.profiles to authenticated;

-- connections: only the two people involved. Creating/accepting goes through the functions above.
create policy conn_read   on public.connections for select to authenticated using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy conn_delete on public.connections for delete to authenticated using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy blocks_all  on public.blocks for all to authenticated using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- circles
create policy circles_read   on public.circles for select to authenticated using (privacy in ('public','request') or is_circle_member(id) or owner_id = auth.uid());
create policy circles_insert on public.circles for insert to authenticated with check (owner_id = auth.uid());
create policy circles_update on public.circles for update to authenticated using (is_circle_mod(id));
create policy circles_delete on public.circles for delete to authenticated using (owner_id = auth.uid());
create policy cm_read   on public.circle_members for select to authenticated using (user_id = auth.uid() or is_circle_member(circle_id));
create policy cm_join   on public.circle_members for insert to authenticated with check (
  (user_id = auth.uid() and role = 'member' and exists (select 1 from circles c where c.id = circle_id and c.privacy = 'public') and status = 'active')
  or (user_id = auth.uid() and role = 'member' and status = 'requested' and exists (select 1 from circles c where c.id = circle_id and c.privacy = 'request'))
  or (user_id = auth.uid() and role = 'owner' and exists (select 1 from circles c where c.id = circle_id and c.owner_id = auth.uid()))
  or (is_circle_mod(circle_id) and is_mutual(auth.uid(), user_id)));
create policy cm_update on public.circle_members for update to authenticated using (is_circle_mod(circle_id));
create policy cm_leave  on public.circle_members for delete to authenticated using (user_id = auth.uid() or is_circle_mod(circle_id));

-- the Wall
create policy posts_read   on public.posts for select to authenticated using (can_see_post(posts));
create policy posts_insert on public.posts for insert to authenticated with check (author_id = auth.uid() and not is_suspended(auth.uid()) and (visibility <> 'circle' or is_circle_member(circle_id)));
create policy posts_update on public.posts for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
revoke update, insert on public.posts from authenticated;     -- authors can never set their own moderation status
grant  insert (author_id, kind, body, media, meta, visibility, circle_id) on public.posts to authenticated;
grant  update (body, media, meta, visibility, circle_id, deleted_at) on public.posts to authenticated;
revoke insert, update on public.comments from authenticated;
grant  insert (post_id, author_id, parent_id, body) on public.comments to authenticated;
create policy posts_delete on public.posts for delete to authenticated using (author_id = auth.uid() or (visibility = 'circle' and is_circle_mod(circle_id)));
create policy aud_read   on public.post_audience for select to authenticated using (user_id = auth.uid() or is_post_author(post_id));
create policy aud_manage on public.post_audience for all to authenticated using (is_post_author(post_id)) with check (is_post_author(post_id));
create policy react_read   on public.reactions for select to authenticated using (can_see_post_id(post_id));
create policy react_insert on public.reactions for insert to authenticated with check (user_id = auth.uid() and can_see_post_id(post_id));
create policy react_update on public.reactions for update to authenticated using (user_id = auth.uid());
create policy react_delete on public.reactions for delete to authenticated using (user_id = auth.uid());
create policy com_read   on public.comments for select to authenticated using (can_see_post_id(post_id) and (moderation_status = 'ok' or author_id = auth.uid()));
create policy com_insert on public.comments for insert to authenticated with check (author_id = auth.uid() and not is_suspended(auth.uid()) and can_see_post_id(post_id));
create policy com_delete on public.comments for delete to authenticated using (author_id = auth.uid() or is_post_author(post_id));
create policy saves_own on public.saves for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and can_see_post_id(post_id));

-- Listen Along: only while it hasn't expired, never to blocked people
create policy listen_read on public.listening for select to authenticated using (
  user_id = auth.uid() or (visibility = 'mutuals' and expires_at > now() and is_mutual(user_id, auth.uid())));
create policy listen_own  on public.listening for delete to authenticated using (user_id = auth.uid());

-- chats: members only
create policy conv_read   on public.conversations for select to authenticated using (is_conv_member(id));
create policy cmem_read   on public.conversation_members for select to authenticated using (is_conv_member(conversation_id));
create policy cmem_leave  on public.conversation_members for delete to authenticated using (user_id = auth.uid());
create policy msg_read    on public.messages for select to authenticated using (is_conv_member(conversation_id));
create policy msg_insert  on public.messages for insert to authenticated with check (sender_id = auth.uid() and not is_suspended(auth.uid()) and can_message(conversation_id));
create policy msg_delete  on public.messages for delete to authenticated using (sender_id = auth.uid());

-- my world: strictly private to the owner
create policy journals_own on public.journals        for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy entries_own  on public.journal_entries for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid() and exists (select 1 from journals j where j.id = journal_id and j.owner_id = auth.uid()));
create policy library_own  on public.library_items   for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy recipes_own  on public.recipes         for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- cards: sender and recipient only. The recipient may only mark opened/saved.
create policy cards_read   on public.cards for select to authenticated using (sender_id = auth.uid() or recipient_id = auth.uid());
create policy cards_update on public.cards for update to authenticated using (recipient_id = auth.uid());
revoke update on public.cards from authenticated;
grant  update (opened_at, saved) on public.cards to authenticated;

-- invitations: host + guests. Guests may only change their own RSVP.
create policy inv_read   on public.invitations for select to authenticated using (host_id = auth.uid() or is_invited(id));
create policy inv_insert on public.invitations for insert to authenticated with check (host_id = auth.uid());
create policy inv_update on public.invitations for update to authenticated using (host_id = auth.uid());
create policy inv_delete on public.invitations for delete to authenticated using (host_id = auth.uid());
create policy ig_read    on public.invitation_guests for select to authenticated using (guest_id = auth.uid() or is_host(invitation_id));
create policy ig_update  on public.invitation_guests for update to authenticated using (guest_id = auth.uid());
revoke update on public.invitation_guests from authenticated;
grant  update (rsvp, responded_at) on public.invitation_guests to authenticated;

-- games: players only
create policy room_read   on public.game_rooms for select to authenticated using (host_id = auth.uid() or is_room_player(id));
create policy room_insert on public.game_rooms for insert to authenticated with check (host_id = auth.uid());
create policy room_update on public.game_rooms for update to authenticated using (host_id = auth.uid());
create policy gp_read   on public.game_players for select to authenticated using (user_id = auth.uid() or is_room_host(room_id) or is_room_player(room_id));
create policy gp_insert on public.game_players for insert to authenticated with check (is_room_host(room_id) and (user_id = auth.uid() or is_mutual(auth.uid(), user_id)));

-- notifications & safety
create policy notif_read   on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notif_update on public.notifications for update to authenticated using (user_id = auth.uid());
revoke update on public.notifications from authenticated;
grant  update (read_at) on public.notifications to authenticated;
create policy prefs_own    on public.notification_prefs for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy reports_ins  on public.reports for insert to authenticated with check (reporter_id = auth.uid());
create policy reports_read on public.reports for select to authenticated using (reporter_id = auth.uid());

-- creation of connections / conversations / notifications happens ONLY through the functions above
revoke insert, update on public.connections from authenticated;
revoke insert, update, delete on public.conversations from authenticated;
revoke insert, update on public.conversation_members from authenticated;
revoke insert, update, delete on public.notifications from authenticated;
grant  update (read_at) on public.notifications to authenticated;
revoke insert on public.cards from authenticated;
revoke insert, delete on public.invitation_guests from authenticated;

-- live updates for chats, reactions, comments, notifications, games (Supabase only)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages, public.reactions, public.comments, public.notifications, public.game_rooms, public.game_players, public.listening;
  end if; end $$;
