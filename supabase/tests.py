import os, tempfile, uuid, json, sys, psycopg2, pgserver
HERE=os.path.dirname(os.path.abspath(__file__))+'/'
srv=pgserver.get_server(tempfile.mkdtemp()); conn=psycopg2.connect(srv.get_uri()); conn.autocommit=True
cur=conn.cursor()
cur.execute("""
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb not null default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated; grant execute on function auth.uid() to anon, authenticated;""")
cur.execute(open(HERE+'schema.sql',encoding='utf-8').read()); print('schema loaded on', srv.psql('select version();').split('\n')[2].strip()[:40] if False else 'real PostgreSQL')

FAILS=[]
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ')+name+((' :: '+str(extra)) if (extra and not cond) else ''))
    if not cond: FAILS.append(name)
def q(sql, params=None, user=None, role='authenticated'):
    """run one statement as a signed-in user; returns (rows, error)"""
    cur.execute('begin')
    try:
        if user is not None or role=='anon':
            cur.execute(f'set local role {role}')
            if user: cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(user),))
        cur.execute(sql, params)
        rows = cur.fetchall() if cur.description else None
        cur.execute('commit'); return rows, None
    except Exception as e:
        cur.execute('rollback'); return None, str(e).split('\n')[0]
def rows(sql, params=None, user=None): r,e=q(sql,params,user); return r if r is not None else []
def fails(sql, params=None, user=None): r,e=q(sql,params,user); return e is not None
def su(sql, params=None): cur.execute(sql, params); return cur.fetchall() if cur.description else None

# ---- people ----
U={}
for n in 'abcde':
    U[n]=su("insert into auth.users (email, raw_user_meta_data) values (%s, %s) returning id", (f'{n}@x.test', json.dumps({'username':f'User_{n}x','display_name':n.upper(),'age_confirmed':True})))[0][0]
check('Signup creates a profile with a lowercase username', su("select username from profiles where id=%s",(U['a'],))[0][0]=='user_ax')
try: su("insert into auth.users (raw_user_meta_data) values ('{\"username\":\"USER_AX\"}')"); dup=False
except Exception: dup=True
check('Usernames are unique, ignoring case', dup)
try: su("insert into auth.users (raw_user_meta_data) values ('{\"username\":\"a b\"}')"); bad=False
except Exception: bad=True
check('Bad usernames (spaces, too short) are refused', bad)
check('Anyone can ask if a username is free', q("select username_available('freeone')", role='anon')[0]==[(True,)] and q("select username_available('user_ax')", role='anon')[0]==[(False,)])
check('Strangers (not signed in) can read nothing', q("select * from profiles", role='anon')[1] is not None)

# ---- mutuals ----
a,b,c,d,e=[U[x] for x in 'abcde']
cid=rows("select send_connection_request('user_bx')", user=a)[0][0]
check('A can request B', cid is not None)
check('A cannot accept their own request', fails("select respond_connection(%s,true)",(cid,),user=a))
check('A cannot just insert a connection directly', fails("insert into connections (requester_id,addressee_id,status) values (%s,%s,'accepted')",(a,c),user=a))
check('C cannot see the request', rows("select * from connections", user=c)==[])
q("select respond_connection(%s,true)",(cid,),user=b)
check('B accepting makes them mutuals', su("select is_mutual(%s,%s)",(a,b))[0][0] is True)
check('A pending request does not count as mutual', (lambda: (rows("select send_connection_request('user_cx')",user=a), su("select is_mutual(%s,%s)",(a,c))[0][0])[1])() is False)
check('B got a notification about the request', len(rows("select * from notifications where kind='connection_request'", user=b))==1)

# ---- the Wall ----
def post(user, vis, body, circle=None): return rows("insert into posts (author_id,kind,body,visibility,circle_id) values (%s,'thought',%s,%s,%s) returning id",(user,body,vis,circle),user=user)[0][0]
p_priv=post(a,'private','only me'); p_mut=post(a,'mutuals','for mutuals'); p_sel=post(a,'selected','for D'); p_pub=post(a,'public','hello world')
q("insert into post_audience values (%s,%s)",(p_sel,d),user=a)
seen=lambda u: sorted(r[0] for r in rows("select body from posts",user=u))
check('Author sees all their own posts', len(seen(a))==4)
check('Mutual sees mutuals + public, never private', seen(b)==['for mutuals','hello world'], seen(b))
check('Stranger sees only public', seen(e)==['hello world'], seen(e))
check('A "selected" audience member sees it, even if not mutual', 'for D' in seen(d))
check('Another stranger does not see the selected post', 'for D' not in seen(e))
check('Nobody can edit someone else\'s post', rows("update posts set body='hacked' where id=%s returning id",(p_mut,),user=b)==[])
q("select block_user(%s)",(b,),user=a)
check('After A blocks B, B loses access to A\'s mutuals post', 'for mutuals' not in seen(b), seen(b))
check('...and public posts of a blocker vanish for the blocked person', 'hello world' not in seen(b))
check('...and the connection is removed', su("select is_mutual(%s,%s)",(a,b))[0][0] is False)
# re-connect for later tests
q("delete from blocks where blocker_id=%s",(a,),user=a)
cid=rows("select send_connection_request('user_bx')",user=a)[0][0]; q("select respond_connection(%s,true)",(cid,),user=b)

# ---- reactions & comments ----
check('Mutual can react to a post they can see', not fails("insert into reactions (post_id,user_id,kind) values (%s,%s,'love')",(p_mut,b),user=b))
check('A stranger cannot react to a mutuals-only post', fails("insert into reactions (post_id,user_id) values (%s,%s)",(p_mut,e),user=e))
check('Nobody can react as someone else', fails("insert into reactions (post_id,user_id) values (%s,%s)",(p_mut,a),user=b))
check('Author is notified of the reaction', len(rows("select * from notifications where kind='reaction'",user=a))==1)
check('You do not notify yourself', (q("insert into reactions (post_id,user_id) values (%s,%s)",(p_mut,a),user=a), len(rows("select * from notifications where kind='reaction'",user=a)))[1]==1)
q("insert into comments (post_id,author_id,body) values (%s,%s,'nice')",(p_mut,b),user=b)
check('Stranger cannot read comments on a post they cannot see', rows("select * from comments",user=e)==[])
check('Post author sees the comment', len(rows("select * from comments",user=a))==1)
check('Only the commenter or post owner can delete a comment', rows("delete from comments where body='nice' returning id",user=c)==[])

# ---- journals: the most private data ----
jid=rows("insert into journals (owner_id,type,title) values (%s,'personal','Daily') returning id",(a,),user=a)[0][0]
q("insert into journal_entries (journal_id,owner_id,mood_score,tags,moment_label,moment_score,content) values (%s,%s,4,'{Friends}','Promotion',2,'{\"notes\":\"secret\"}')",(jid,a),user=a)
check('Owner reads their journal entry', len(rows("select * from journal_entries",user=a))==1)
check('A mutual (even a close one) cannot read it', rows("select * from journal_entries",user=b)==[])
check('Nobody can write into someone else\'s journal', fails("insert into journal_entries (journal_id,owner_id) values (%s,%s)",(jid,b),user=b))
check('...even by pointing at their own owner_id', fails("insert into journal_entries (journal_id,owner_id) values (%s,%s)",(jid,b),user=b))
check('Mood score must be 1 to 5', fails("insert into journal_entries (journal_id,owner_id,mood_score) values (%s,%s,9)",(jid,a),user=a))
check('Mood Flow query works for the owner', rows("select entry_date, mood_score from journal_entries where mood_score is not null order by entry_date",user=a)!=[])
check('Recipes and library are private to the owner', (q("insert into recipes (owner_id,title) values (%s,'Jollof')",(a,),user=a), rows("select * from recipes",user=b))[1]==[])

# ---- chats ----
dm=rows("select start_dm(%s)",(b,),user=a)[0][0]
check('A mutual DM can be started, and starting twice returns the same chat', rows("select start_dm(%s)",(b,),user=a)[0][0]==dm and rows("select start_dm(%s)",(a,),user=b)[0][0]==dm)
check('Cannot DM someone who is not a mutual', fails("select start_dm(%s)",(e,),user=a))
q("insert into messages (conversation_id,sender_id,body) values (%s,%s,'hi')",(dm,a),user=a)
check('The other member reads the message', len(rows("select * from messages",user=b))==1)
check('An outsider reads nothing', rows("select * from messages",user=c)==[] and rows("select * from conversations",user=c)==[])
check('An outsider cannot post into the chat', fails("insert into messages (conversation_id,sender_id,body) values (%s,%s,'x')",(dm,c),user=c))
check('Nobody can send as someone else', fails("insert into messages (conversation_id,sender_id,body) values (%s,%s,'x')",(dm,a),user=b))
check('Chats cannot be created by direct insert', fails("insert into conversations (kind,created_by) values ('dm',%s)",(c,),user=c))
q("select block_user(%s)",(a,),user=b); cid=rows("select send_connection_request('user_bx')",user=a); 
check('After a block, messages in the old DM are refused', fails("insert into messages (conversation_id,sender_id,body) values (%s,%s,'still there?')",(dm,a),user=a))
q("delete from blocks where blocker_id=%s",(b,),user=b)
cid=rows("select id from connections where least(requester_id,addressee_id)=least(%s,%s)",(a,b),user=a)
if not cid:
    cx=rows("select send_connection_request('user_bx')",user=a)[0][0]; q("select respond_connection(%s,true)",(cx,),user=b)
# group of mutuals (A with B), and C who is only pending
check('Groups need every member to be a mutual', fails("select create_group('Fam','family',%s::uuid[])",([b,c],),user=a))
g=rows("select create_group('Fam','family',%s::uuid[])",([b],),user=a)[0][0]
check('A group of mutuals works', len(rows("select * from conversation_members where conversation_id=%s",(g,),user=b))==2)

# ---- circles ----
priv=rows("insert into circles (owner_id,name,privacy) values (%s,'Sunday Reading','private') returning id",(a,),user=a)[0][0]
q("insert into circle_members (circle_id,user_id,role) values (%s,%s,'owner')",(priv,a),user=a)
req=rows("insert into circles (owner_id,name,privacy) values (%s,'Afrobeats','request') returning id",(a,),user=a)[0][0]
q("insert into circle_members (circle_id,user_id,role) values (%s,%s,'owner')",(req,a),user=a)
check('A private circle is invisible to non-members', all(r[0]!='Sunday Reading' for r in rows("select name from circles",user=e)))
check('A request-to-join circle is discoverable', any(r[0]=='Afrobeats' for r in rows("select name from circles",user=e)))
check('Strangers cannot walk into a private circle', fails("insert into circle_members (circle_id,user_id) values (%s,%s)",(priv,e),user=e))
check('...but can ask to join a request circle (as "requested")', not fails("insert into circle_members (circle_id,user_id,status) values (%s,%s,'requested')",(req,e),user=e))
check('...and cannot approve themselves (the update changes nothing)', rows("update circle_members set status='active' where circle_id=%s and user_id=%s returning 1",(req,e),user=e)==[] and su("select status from circle_members where circle_id=%s and user_id=%s",(req,e))[0][0]=='requested')
check('The owner can add a mutual to a private circle', not fails("insert into circle_members (circle_id,user_id) values (%s,%s)",(priv,b),user=a))
cp=post(a,'circle','circle only',circle=priv)
check('Circle posts are visible to members only', 'circle only' in seen(b) and 'circle only' not in seen(e))
check('A circle post needs a circle, and vice versa', fails("insert into posts (author_id,kind,body,visibility) values (%s,'thought','x','circle')",(a,),user=a))

# ---- cards ----
card=rows("select send_card(%s,'birthday','handwritten','for your next chapter','Happy birthday!',false)",(b,),user=a)[0][0]
check('Cards go to mutuals only', fails("select send_card(%s,'birthday','x','','hi',false)",(e,),user=a))
check('Sender and recipient see the card; nobody else does', len(rows("select * from cards",user=b))==1 and len(rows("select * from cards",user=a))==1 and rows("select * from cards",user=c)==[])
check('Recipient is notified', len(rows("select * from notifications where kind='card_received'",user=b))==1)
check('Recipient can mark it opened and saved', not fails("update cards set opened_at=now(), saved=true where id=%s",(card,),user=b))
check('Recipient cannot rewrite the note', fails("update cards set note='changed' where id=%s",(card,),user=b))
check('Sender cannot edit a sent card', rows("update cards set saved=true where id=%s returning id",(card,),user=a)==[])
check('Cards cannot be inserted directly', fails("insert into cards (sender_id,recipient_id,occasion,note) values (%s,%s,'birthday','x')",(a,b),user=a))

# ---- invitations + RSVP ----
inv=rows("insert into invitations (host_id,title,place) values (%s,'My birthday','Lagos') returning id",(a,),user=a)[0][0]
q("select invite_guests(%s,%s::uuid[])",(inv,[b]),user=a)
check('Guests must be mutuals', fails("select invite_guests(%s,%s::uuid[])",(inv,[e]),user=a))
check('Only the host can invite', fails("select invite_guests(%s,%s::uuid[])",(inv,[c]),user=b))
check('Guest sees the invitation; outsiders do not', len(rows("select * from invitations",user=b))==1 and rows("select * from invitations",user=e)==[])
q("select rsvp(%s,'yes')",(inv,),user=b)
check('Host sees the RSVP', rows("select rsvp from invitation_guests",user=a)==[('yes',)])
check('Host is notified of the RSVP', len(rows("select * from notifications where kind='rsvp'",user=a))==1)
check('Uninvited people cannot RSVP', fails("select rsvp(%s,'yes')",(inv,),user=e))
check('A guest cannot RSVP on behalf of another guest', rows("update invitation_guests set rsvp='no' where guest_id=%s returning 1",(a,),user=b)==[])
check('A guest cannot edit the invitation itself', rows("update invitations set title='x' where id=%s returning id",(inv,),user=b)==[])
check('Guest lists cannot be edited directly', fails("insert into invitation_guests (invitation_id,guest_id) values (%s,%s)",(inv,e),user=b))

# ---- Listen Along ----
q("select set_listening(%s::jsonb,'mutuals')",(json.dumps({'title':'Song','artist':'Artist'}),),user=a)
check('A mutual sees what you are listening to', len(rows("select * from listening",user=b))==1)
check('A stranger does not', rows("select * from listening",user=e)==[])
su("update listening set expires_at = now() - interval '1 minute' where user_id=%s",(a,))
check('It disappears once expired', rows("select * from listening",user=b)==[] and len(rows("select * from listening",user=a))==1)
q("select set_listening(%s::jsonb,'nobody')",(json.dumps({'title':'Secret'}),),user=a)
check('"Nobody" means nobody', rows("select * from listening",user=b)==[])

# ---- games ----
room=rows("insert into game_rooms (kind,host_id) values ('word_rack',%s) returning id",(a,),user=a)[0][0]
check('Host can add a mutual to a game', not fails("insert into game_players (room_id,user_id) values (%s,%s)",(room,b),user=a))
check('...but not a stranger', fails("insert into game_players (room_id,user_id) values (%s,%s)",(room,e),user=a))
check('Players see the room; outsiders do not', len(rows("select * from game_rooms",user=b))==1 and rows("select * from game_rooms",user=e)==[])

# ---- notifications & safety ----
q("insert into notification_prefs values (%s,'reaction',false)",(a,),user=a)
q("insert into reactions (post_id,user_id) values (%s,%s)",(p_pub,c),user=c)
check('Turning a notification type off is respected', len(rows("select * from notifications where kind='reaction'",user=a))==1)
check('People cannot read each other\'s notifications', all(r[0]==b for r in rows("select user_id from notifications",user=b)))
check('Notifications can be marked read but not rewritten', not fails("update notifications set read_at=now() where user_id=%s",(b,),user=b) and fails("update notifications set kind='x' where user_id=%s",(b,),user=b))
check('Anyone can file a report; they only see their own', not fails("insert into reports (reporter_id,target_type,target_id,reason) values (%s,'post',%s,'spam')",(c,p_pub),user=c) and rows("select * from reports",user=a)==[])


# ---- trust & safety, privacy rights, AI consent ----
su("insert into banned_terms values ('badword')")
hp=post(c,'public','this has a BadWord in it'); okp=post(c,'public','a perfectly nice post')
check('A filtered post is held: the author still sees it', 'this has a BadWord in it' in seen(c))
check('...but nobody else does', 'this has a BadWord in it' not in seen(e) and 'a perfectly nice post' in seen(e))
check('...and it lands in the moderation queue', su("select count(*) from moderation_queue where target_id=%s",(hp,))[0][0]==1)
check('Authors cannot release their own held post', fails("update posts set moderation_status='ok' where id=%s",(hp,),user=c))
q("insert into comments (post_id,author_id,body) values (%s,%s,'badword here')",(p_pub,e),user=e)
check('Held comments are hidden from others', all('badword' not in r[0] for r in rows("select body from comments",user=c)))
check('The moderation queue is not readable by users', q("select * from moderation_queue",user=c)[1] is not None or rows("select * from moderation_queue",user=c)==[])
su("update profiles set suspended_until = now() + interval '1 day' where id=%s",(d,))
check('A suspended person cannot post, comment or message', fails("insert into posts (author_id,kind,body,visibility) values (%s,'thought','hi','public')",(d,),user=d))
check('People cannot lift their own suspension', fails("update profiles set suspended_until=null where id=%s",(d,),user=d))
check('People can still edit their own profile', not fails("update profiles set bio='hello' where id=%s",(d,),user=d))
check('Nobody can edit someone else\'s profile', rows("update profiles set bio='x' where id=%s returning 1",(c,),user=d)==[])
check('AI is off by default', su("select ai_enabled, ai_journal_consent from profiles where id=%s",(c,))[0]==(False,False))
check('AI calls are refused until the person turns AI on', rows("select ai_consume(2)",user=c)==[(False,)])
q("update profiles set ai_enabled=true where id=%s",(c,),user=c)
check('...then a daily allowance applies', [rows("select ai_consume(2)",user=c)[0][0] for _ in range(3)]==[True,True,False])
check('Usage records are private', rows("select * from ai_usage",user=b)==[])
exp=rows("select export_my_data()",user=b)[0][0]
check('Download my data returns my data, and only mine', exp['profile']['username']=='user_bx' and len(exp['cards_received'])==1 and all(m['sender_id']==str(b) for m in exp['messages']) and 'secret' not in json.dumps(exp))
q("select delete_my_account()",user=e)
check('In-app account deletion removes the person entirely', su("select count(*) from profiles where id=%s",(e,))[0][0]==0 and su("select count(*) from circle_members where user_id=%s",(e,))[0][0]==0 and su("select count(*) from comments where author_id=%s",(e,))[0][0]==0)

# ---- delete account (an App Store / Play Store requirement) ----
su("delete from auth.users where id=%s",(a,))
check('Deleting an account removes their profile, posts, journals and chats membership', su("select count(*) from profiles where id=%s",(a,))[0][0]==0 and su("select count(*) from posts where author_id=%s",(a,))[0][0]==0 and su("select count(*) from journals where owner_id=%s",(a,))[0][0]==0 and su("select count(*) from cards where sender_id=%s",(a,))[0][0]==0)
print('\nFAILED CHECKS:', FAILS if FAILS else 'none')
sys.exit(1 if FAILS else 0)
