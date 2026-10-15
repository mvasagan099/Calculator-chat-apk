\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('60000000-0000-0000-0000-000000000001'),('60000000-0000-0000-0000-000000000002');
update public.user_settings set photo_privacy='nobody',invitation_privacy='nobody' where user_id='60000000-0000-0000-0000-000000000002';
insert into storage.objects(bucket_id,name,metadata) values('avatars','60000000-0000-0000-0000-000000000002/profile.jpg','{"size":10,"mimetype":"image/jpeg"}');
insert into public.media_validations values('avatars','60000000-0000-0000-0000-000000000002/profile.jpg','60000000-0000-0000-0000-000000000002','image/jpeg',10,now());
update public.profiles set avatar_path='60000000-0000-0000-0000-000000000002/profile.jpg' where id='60000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000001',true);
select public.create_group('Private invitations') as gid \gset
select set_config('test.gid',:'gid',true);
update public.user_settings set online_visible=false where user_id=auth.uid();
do $$begin
 begin insert into realtime.messages(id,extension,topic) values(1,'presence','conversation:'||current_setting('test.gid'));raise exception 'online preference bypass';exception when insufficient_privilege then null;end;
end$$;
insert into realtime.messages(id,extension,topic) values(2,'broadcast','conversation:'||:'gid');
do $$begin
 if exists(select 1 from storage.objects where bucket_id='avatars') then raise exception 'private photo leaked';end if;
 begin perform public.manage_group(current_setting('test.gid')::uuid,'invite','60000000-0000-0000-0000-000000000002');raise exception 'private invitations bypass';exception when raise_exception then if sqlerrm='private invitations bypass' then raise;end if;end;
end$$;
reset role;
update public.user_settings set photo_privacy='contacts',invitation_privacy='contacts',online_visible=false where user_id='60000000-0000-0000-0000-000000000002';
insert into public.contacts(owner_id,contact_id) values('60000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000001');
set local role authenticated;
do $$begin if not exists(select 1 from storage.objects where bucket_id='avatars') then raise exception 'consenting contact photo denied';end if;end$$;
select public.manage_group(:'gid','invite','60000000-0000-0000-0000-000000000002');
rollback;
\echo 'Profile-photo Storage privacy, online publication and recipient-controlled invitation privacy passed.'
