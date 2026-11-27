import pixeltable_pgserver as pg, psycopg2, tempfile, re, json
d=tempfile.mkdtemp(); s=pg.get_server(d); c=psycopg2.connect(s.get_uri()); c.autocommit=True; k=c.cursor()
A='00000000-0000-0000-0000-00000000000a';B='00000000-0000-0000-0000-00000000000b';C='00000000-0000-0000-0000-00000000000c'
k.execute("create role anon; create role authenticated; create role authenticator; create schema auth; create schema extensions; set check_function_bodies=off")
k.execute("""
create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid',true),'')::uuid $$;
create table auth.users(id uuid primary key, email_confirmed_at timestamptz, phone_confirmed_at timestamptz);
create table auth.mfa_factors(user_id uuid, status text);
create function extensions.crypt(a text,b text) returns text language sql as $$ select 'h:'||a $$;
create function extensions.gen_salt(a text) returns text language sql as $$ select 'x' $$;
create table profiles(id uuid primary key, username text, created_at timestamptz default now());
create table site_staff(user_id uuid primary key, role text);
create table casier(user_id uuid, kind text); create table account_flags(user_id uuid, flag text);
create table contact_emails(user_id uuid, verified_at timestamptz); create table contact_phones(user_id uuid, verified_at timestamptz);
create table legal_versions(version int, published_at timestamptz); create table legal_acceptances(user_id uuid, version int);
create table admin_logs(id serial, created_at timestamptz default now(), staff_name text, action text, target text); create table log_alerts(id serial, at timestamptz default now(), tbl text, op text);
create table rate_hits(id serial, ts timestamptz);
create table conversations(id uuid primary key default gen_random_uuid(), kind text, mode text, hub text, created_by uuid);
create table conversation_members(conversation_id uuid, user_id uuid, role text default 'member', primary key(conversation_id,user_id));
create table messages(id serial, conversation_id uuid, sender_id uuid, kind text, body text);
create table group_items(id serial primary key, conv uuid, kind text, created_by uuid, data jsonb default '{}', closed bool default false);
create table tournaments(id serial primary key, creator uuid);
create table conversation_bans(id serial, conversation_id uuid, user_id uuid, by_id uuid, seconds numeric, until timestamptz, lifted_at timestamptz);
create function is_member(c uuid) returns bool language sql as $$ select exists(select 1 from conversation_members where conversation_id=c and user_id=auth.uid()) $$;
create function _is_member(c uuid) returns bool language sql as $$ select is_member(c) $$;
create function _is_cadmin(c uuid) returns bool language sql as $$ select exists(select 1 from conversation_members where conversation_id=c and user_id=auth.uid() and role='admin') $$;
create function staff_rank(p text) returns int language sql as $$ select case p when 'moderator' then 1 when 'admin' then 2 when 'chief' then 3 when 'commander' then 4 else 0 end $$;
create function staff_rank_of(u uuid) returns int language sql as $$ select coalesce((select staff_rank(role) from site_staff where user_id=u),0) $$;
create function staff_rank_me() returns int language sql as $$ select staff_rank_of(auth.uid()) $$;
create function rate_ok(a text,b int,c int) returns void language sql as $$ select 1 $$;
create function log_admin(a text,b text,c jsonb) returns void language sql as $$ select 1 $$;
create function req_ip() returns text language sql as $$ select nullif(current_setting('app.ip',true),'') $$;
create function conv_is_admin(a uuid,b uuid) returns bool language sql as $$ select false $$;
create table conversation_rights(conversation_id uuid, user_id uuid, granted_by uuid, primary key(conversation_id,user_id));
""")
sql=open('/home/claude/communicer/database/sql/patch_lot24.sql').read()
def sect(a,b):
    i=sql.index(a); j=sql.index(b) if b else len(sql); return sql[i:j]
k.execute(sect("-- ---------- 9)","-- ---------- 10)"))
k.execute(open('/home/claude/communicer/database/sql/patch_lot25.sql').read())
for u,n,r_ in ((A,'ana',None),(B,'bob','admin'),(C,'cmd','commander')):
    k.execute("insert into profiles(id,username,created_at) values(%s,%s,now()-interval '90 days')",(u,n)); k.execute("insert into auth.users(id) values(%s)",(u,))
    if r_: k.execute("insert into site_staff values(%s,%s)",(u,r_))
def r(q,uid=None,*a):
    k.execute("select set_config('app.uid',%s,false)",(uid or '',))
    try: k.execute(q,a); return k.fetchall()
    except Exception as e: return 'ERR '+str(e).strip().split('\n')[0]
G='11111111-1111-1111-1111-111111111111'
k.execute("insert into conversations(id,kind,mode) values(%s,'group','clear')",(G,))
for u,ro in ((A,'member'),(B,'member'),(C,'admin')): k.execute("insert into conversation_members values(%s,%s,%s)",(G,u,ro))
print('commandant premier NIP (seq puis pin)',r("select panel_seq('DDDLLUDDLU')",C),r("select panel_pin('ABCDEFGH')",C))
print('pin ana sans NIP defini?',r("select panel_seq('DDDLLUDDLU')",A),r("select panel_pin('ABCDEFGH')",A),r("select panel_state()",A))
r("select panel_seq('DDDLLUDDLU')",B);print('bob pin',r("select panel_pin('abcdefgh')",B))
print('console',str(r("select panel_console(5)",B))[:120])
print('ping/active',r("select panel_ping()",B),r("select panel_active()",C))
print('vanish conv',r("select panel_vanish(true,%s)",B,G),'vu par ana',r("select panel_vanished()",A),'vu par bob',r("select panel_vanished()",B))
print('vanish global',r("select panel_vanish(true)",B),r("select panel_vanished()",A))
print('right',r("select panel_right(%s,'ana',true)",B,G),r("select count(*) from conversation_rights",B))
print('cban',r("select panel_cban(%s,'ana',60)",B,G),r("select count(*) from conversation_members where conversation_id=%s",B,G),r("select count(*) from conversation_bans where lifted_at is null",B))
print('cunban',r("select panel_cunban(%s,'ana')",B,G),r("select count(*) from conversation_bans where lifted_at is null",B))
k.execute("insert into conversation_members values(%s,%s,'member')",(G,A))
print('remove ana',r("select panel_remove(%s,'ana')",B,G),r("select count(*) from conversation_members where conversation_id=%s",B,G))
print('remove commandant par admin',r("select panel_remove(%s,'cmd')",B,G))
k.execute("insert into conversation_members values(%s,%s,'member')",(G,A))
print('speak sans volontaire (panneau)',r("select speak_as(%s,'ana','bonjour','test justifie ok')",B,G),r("select via from messages where kind='text'",B))
print('motif court',r("select speak_as(%s,'ana','x','court')",B,G))
print('ana non staff',r("select speak_as(%s,'bob','x','motif assez long')",A,G))
k.execute("update panel_users set unlocked=false where user_id=%s",(B,))
print('bob sans panneau, non volontaire',r("select speak_as(%s,'ana','x','motif assez long')",B,G))
print('volontaire',r("select speak_vol_set(true)",A),r("select speak_vol_me()",A),r("select speak_as(%s,'ana','salut','motif assez long')",B,G),r("select via from messages where kind='text' order by id desc limit 1",B))
print('peek',r("select panel_peek_ok(%s)",A,C),r("select panel_peek_ok(%s)",A,A))
k.execute("insert into group_items(conv,kind,created_by) values(%s,'poll',%s)",(G,A))
print('gi_set par autre (admin groupe commandant)',r("select gi_set(1,'{\"a\":1}'::jsonb,true)",C),'auteur',r("select gi_set(1,'{\"a\":1}'::jsonb,true)",A),'del par admin groupe',r("select gi_del(1)",C))
k.execute("insert into tournaments(creator) values(%s)",(A,))
print('boss commandant',r("select _ev_boss(1)",C),'createur',r("select _ev_boss(1)",A),'t_delete cmd',r("select t_delete(1)",C))
