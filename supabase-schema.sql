-- Supabase Schema for CadernetaGuimaGym
-- Run this in the SQL Editor (https://supabase.com/dashboard → SQL Editor)

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Users table
CREATE TABLE users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT NOT NULL,
  email TEXT NOT NULL,
  avatar TEXT DEFAULT '01',
  location TEXT DEFAULT 'Academia',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Stickers table
CREATE TABLE stickers (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL,
  owned INTEGER DEFAULT 0,
  tradeable INTEGER DEFAULT 0,
  UNIQUE(user_id, sticker_id)
);

-- Trade requests table
CREATE TABLE trade_requests (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  from_user_id UUID NOT NULL REFERENCES users(id),
  from_username TEXT NOT NULL,
  from_email TEXT NOT NULL,
  to_user_id UUID NOT NULL REFERENCES users(id),
  to_username TEXT NOT NULL,
  stickers_wanted TEXT[] NOT NULL,
  stickers_offered TEXT[] NOT NULL,
  message TEXT DEFAULT '',
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','accepted','completed','declined')),
  created_at TIMESTAMPTZ DEFAULT now(),
  to_email TEXT,
  completed_at TIMESTAMPTZ,
  completed_by UUID,
  decline_message TEXT
);

-- Indexes
CREATE INDEX idx_stickers_user_id ON stickers(user_id);
CREATE INDEX idx_stickers_user_owned ON stickers(user_id, owned) WHERE owned > 0;
CREATE INDEX idx_trade_requests_to ON trade_requests(to_user_id, status);
CREATE INDEX idx_trade_requests_from ON trade_requests(from_user_id, status);

-- RLS
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE stickers ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view all profiles" ON users FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON users FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile" ON users FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "Stickers are viewable by everyone" ON stickers FOR SELECT USING (true);
CREATE POLICY "Users can insert own stickers" ON stickers FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own stickers" ON stickers FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own stickers" ON stickers FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "Trade requests viewable by involved parties" ON trade_requests
  FOR SELECT USING (auth.uid() = from_user_id OR auth.uid() = to_user_id);
CREATE POLICY "Users can create trade requests" ON trade_requests
  FOR INSERT WITH CHECK (auth.uid() = from_user_id);
-- Both sender and receiver can update the trade request (accept, complete, decline)
CREATE POLICY "Involved users can update trade requests" ON trade_requests
  FOR UPDATE USING (auth.uid() = to_user_id OR auth.uid() = from_user_id);
CREATE POLICY "Sender can delete own trade requests" ON trade_requests
  FOR DELETE USING (auth.uid() = from_user_id);

-- Auto-create 788 stickers on user registration
CREATE OR REPLACE FUNCTION init_user_stickers()
RETURNS TRIGGER AS $$
DECLARE
  i INTEGER;
BEGIN
  FOR i IN 0..787 LOOP
    INSERT INTO stickers (user_id, sticker_id, owned, tradeable)
    VALUES (NEW.id, LPAD(i::TEXT, 3, '0'), 0, 0);
  END LOOP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_user_created
  AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION init_user_stickers();

-- Scan usage tracking (for AI scanner monthly limit)
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

-- RPC function to atomically increment scan count
CREATE OR REPLACE FUNCTION increment_scan_usage(p_user_id UUID, p_month TEXT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO scan_usage (user_id, month, count)
  VALUES (p_user_id, p_month, 1)
  ON CONFLICT (user_id, month)
  DO UPDATE SET count = scan_usage.count + 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
