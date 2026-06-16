-- Migration: Add scan_usage table and increment function
-- Run this in the SQL Editor (https://supabase.com/dashboard -> SQL Editor)

-- Track per-user monthly scan usage
CREATE TABLE IF NOT EXISTS scan_usage (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  month TEXT NOT NULL, -- Format: YYYY-MM
  count INTEGER DEFAULT 0,
  UNIQUE(user_id, month)
);

ALTER TABLE scan_usage ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own scan usage" ON scan_usage
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own scan usage" ON scan_usage
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own scan usage" ON scan_usage
  FOR UPDATE USING (auth.uid() = user_id);

-- RPC function to atomically increment scan count (used by Edge Function with service role)
CREATE OR REPLACE FUNCTION increment_scan_usage(p_user_id UUID, p_month TEXT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO scan_usage (user_id, month, count)
  VALUES (p_user_id, p_month, 1)
  ON CONFLICT (user_id, month)
  DO UPDATE SET count = scan_usage.count + 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
