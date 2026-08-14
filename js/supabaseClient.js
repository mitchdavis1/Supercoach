import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cfg = window.SUPERSTABLE_CONFIG || {};

if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes('YOUR-PROJECT-REF')) {
  console.warn('SuperStable: js/config.js still has placeholder Supabase credentials — auth and data calls will fail until you fill them in.');
}

export const supabase = createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true },
});
