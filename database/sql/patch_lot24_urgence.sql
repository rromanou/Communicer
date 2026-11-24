-- URGENCE : désactive le crochet anti-abus et lève tous les blocages
alter role authenticator reset pgrst.db_pre_request;
delete from public.ip_blocks;
delete from public.ip_hits;
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
