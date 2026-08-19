import { supabase } from './supabaseClient.js';
import { state } from './state.js';

let onAuthChange = () => {};

export function initAuth(callback) {
  onAuthChange = callback;
  supabase.auth.onAuthStateChange(async (event, session) => {
    state.session = session;

    // Landing here via a password-reset email link: supabase-js already
    // established a session from the recovery token in the URL, but that
    // alone doesn't change the password — show a "set new password" form
    // instead of dropping straight into the app. handleSetNewPassword()
    // calling updateUser() fires USER_UPDATED through this same listener,
    // which falls through to the normal signed-in flow below.
    if (event === 'PASSWORD_RECOVERY') {
      showRecoveryForm();
      return;
    }

    if (session) {
      await loadProfile();
    } else {
      state.profile = null;
    }
    onAuthChange(session);
  });
}

function showRecoveryForm() {
  document.getElementById('authGate').style.display = 'flex';
  document.getElementById('appShell').style.display = 'none';
  document.querySelector('.join-tabs').style.display = 'none';
  document.getElementById('aform-signin').style.display = 'none';
  document.getElementById('aform-join').style.display = 'none';
  document.getElementById('aform-recovery').style.display = 'block';
}

async function loadProfile() {
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', state.session.user.id)
    .single();
  if (error) {
    console.error('Could not load profile', error);
    return;
  }
  state.profile = data;
}

export function showAuthError(message) {
  const el = document.getElementById('authError');
  if (!el) return;
  el.textContent = message;
  el.classList.add('show');
}

export function clearAuthError() {
  const el = document.getElementById('authError');
  if (!el) return;
  el.classList.remove('show');
  el.textContent = '';
}

export async function handleSignIn() {
  clearAuthError();
  const username = document.getElementById('authSigninUsername').value.trim();
  const password = document.getElementById('authSigninPassword').value;
  if (!username || !password) {
    showAuthError('Enter your username and password.');
    return;
  }

  const { data: email, error: lookupError } = await supabase.rpc('email_for_username', { p_username: username });
  if (lookupError || !email) {
    showAuthError("We couldn't find that account, or the password is incorrect.");
    return;
  }

  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    showAuthError("We couldn't find that account, or the password is incorrect.");
    return;
  }
}

export async function handleJoin() {
  clearAuthError();
  const username = document.getElementById('authJoinUsername').value.trim();
  const email = document.getElementById('authJoinEmail').value.trim();
  const password = document.getElementById('authJoinPassword').value;

  if (!username || !email || !password) {
    showAuthError('Username, email, and password are all required.');
    return;
  }

  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: { data: { username, display_name: username } },
  });

  if (error) {
    showAuthError(error.message);
    return;
  }

  if (!data.session) {
    showAuthError('Account created — check your email to confirm it, then sign in.');
  }
}

export async function logout() {
  if (!confirm('Log out?')) return;
  await supabase.auth.signOut();
}

export function switchAuthTab(tab) {
  clearAuthError();
  document.getElementById('atab-signin').classList.toggle('active', tab === 'signin');
  document.getElementById('atab-join').classList.toggle('active', tab === 'join');
  document.getElementById('aform-signin').style.display = tab === 'signin' ? 'block' : 'none';
  document.getElementById('aform-join').style.display = tab === 'join' ? 'block' : 'none';
  document.getElementById('aform-recovery').style.display = 'none';
  document.querySelector('.join-tabs').style.display = 'flex';
}

export async function handleForgotPassword() {
  clearAuthError();
  const username = document.getElementById('authSigninUsername').value.trim();
  if (!username) {
    showAuthError('Enter your username above, then click "Forgot password?" again.');
    return;
  }

  const { data: email, error: lookupError } = await supabase.rpc('email_for_username', { p_username: username });
  if (lookupError || !email) {
    showAuthError("We couldn't find that account.");
    return;
  }

  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin + window.location.pathname,
  });
  if (error) {
    showAuthError(error.message);
    return;
  }
  alert('Password reset email sent — check your inbox.');
}

export async function handleSetNewPassword() {
  clearAuthError();
  const password = document.getElementById('recoveryNewPassword').value;
  if (!password || password.length < 6) {
    showAuthError('Password must be at least 6 characters.');
    return;
  }

  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    showAuthError(error.message);
    return;
  }
}
