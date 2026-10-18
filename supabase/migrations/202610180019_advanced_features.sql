-- Migration 202610180019: Advanced Group Admin Controls, Message Edit History RLS, and App Version Management

-- 1. GROUP ADMIN CONTROLS SCHEMA
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS members_can_send BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS members_can_edit_info BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS members_can_invite BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS slow_mode_seconds INT NOT NULL DEFAULT 0;

ALTER TABLE public.conversation_members
  ADD COLUMN IF NOT EXISTS muted_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_message_at TIMESTAMPTZ;

-- Backfill owner_id for existing groups from existing admin member
UPDATE public.groups g
SET owner_id = (
  SELECT cm.user_id FROM public.conversation_members cm
  WHERE cm.conversation_id = g.conversation_id
  ORDER BY CASE WHEN cm.role = 'admin' THEN 0 ELSE 1 END, cm.joined_at ASC
  LIMIT 1
)
WHERE g.owner_id IS NULL;

-- Update role constraint/values if needed: 'owner', 'admin', 'member'
UPDATE public.conversation_members cm
SET role = 'owner'
FROM public.groups g
WHERE cm.conversation_id = g.conversation_id AND cm.user_id = g.owner_id AND cm.role = 'admin';

-- Group Administrative Action Audit Log
CREATE TABLE IF NOT EXISTS public.group_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  actor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  target_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

CREATE INDEX IF NOT EXISTS idx_group_audit_logs_conv_created 
  ON public.group_audit_logs (conversation_id, created_at DESC);

ALTER TABLE public.group_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS group_audit_logs_select ON public.group_audit_logs;
CREATE POLICY group_audit_logs_select ON public.group_audit_logs
  FOR SELECT TO authenticated
  USING (private.is_member(conversation_id));

-- 2. MESSAGE EDIT HISTORY RLS
-- Allow all conversation participants to view message edit revisions for active messages
DROP POLICY IF EXISTS edits_owner ON public.message_edits;
DROP POLICY IF EXISTS edits_members ON public.message_edits;
CREATE POLICY edits_members ON public.message_edits
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.messages m
      WHERE m.id = message_id
        AND m.deleted_at IS NULL
        AND private.is_member(m.conversation_id)
    )
  );

-- 3. APP VERSION CONTROL SCHEMA
ALTER TABLE private.android_releases
  ADD COLUMN IF NOT EXISTS min_supported_build BIGINT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS version_name TEXT NOT NULL DEFAULT '1.0.0',
  ADD COLUMN IF NOT EXISTS release_notes TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS apk_size_bytes BIGINT NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.get_app_version_status(target_abi TEXT, installed_build BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  rel RECORD;
  min_build BIGINT;
  status TEXT;
BEGIN
  PERFORM private.require_session();

  SELECT * INTO rel FROM private.android_releases r
  WHERE r.published AND r.published_at <= now() AND r.abi = target_abi
  ORDER BY r.build_number DESC LIMIT 1;

  IF rel IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'active',
      'installed_build', installed_build,
      'latest_release', null
    );
  END IF;

  SELECT coalesce(max(min_supported_build), 1) INTO min_build
  FROM private.android_releases
  WHERE published AND abi = target_abi;

  IF installed_build < min_build THEN
    status := 'unsupported';
  ELSIF installed_build < rel.build_number THEN
    status := 'deprecated';
  ELSE
    status := 'active';
  END IF;

  RETURN jsonb_build_object(
    'status', status,
    'installed_build', installed_build,
    'min_supported_build', min_build,
    'latest_release', to_jsonb(rel)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_app_version_status(TEXT, BIGINT) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_app_version_status(TEXT, BIGINT) TO authenticated;

-- Realtime publication for audit logs
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' 
      AND schemaname = 'public' 
      AND tablename = 'group_audit_logs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_audit_logs;
  END IF;
END $$;
