-- HINKredience° – úložiště fotografií
--
-- Soukromý bucket "recipe-photos". Cesta souboru:
--   <id uživatele, který fotku nahrál>/<id receptu>/<id fotky>.jpg
-- Nahrávat a mazat smí každý jen ve své složce; číst smí ten, kdo má přístup k receptu.

insert into storage.buckets (id, name, public)
values ('recipe-photos', 'recipe-photos', false)
on conflict (id) do nothing;

create policy recipe_photos_select on storage.objects for select to authenticated
  using (
    bucket_id = 'recipe-photos'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.can_access_recipe(public.try_uuid((storage.foldername(name))[2]))
    )
  );

create policy recipe_photos_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy recipe_photos_update on storage.objects for update to authenticated
  using (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy recipe_photos_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'recipe-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
