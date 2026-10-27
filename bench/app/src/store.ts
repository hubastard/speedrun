// App state: one store read with useStore(selector). What survives a restart (the session,
// the draft note) is saved to a file in the app's documents, so clearState wipes it; the
// remembered account lives in the keychain (SecureStore), which clearState keeps on iOS.
import { File, Paths } from 'expo-file-system';
import * as SecureStore from 'expo-secure-store';
import { useSyncExternalStore } from 'react';

export type Session = 'none' | 'guest' | 'user';
export type Popup = 'notify' | 'rate' | 'badge' | 'survey';
export type CartLine = { key: string; productId: number; size: string; color: string; qty: number; gift: boolean };

type Saved = { session: Session; name: string; phone: string; draft: string; launches: number };

export type State = Saved & {
  cart: CartLine[];
  orders: number;
  points: number;
  popups: Popup[]; // shown one at a time, first first
  toast: { text: string; id: number } | null;
  units: 'Metric' | 'Imperial';
  publicProfile: boolean;
  email: string;
  bio: string;
  pin: string;
  push: boolean;
  emails: boolean;
  promo: string | null; // the applied promo code
  promoTries: number;
  onboarded: boolean; // left the onboarding since the app started
};

const saved = new File(Paths.document, 'state.json');

function load(): Saved {
  const empty: Saved = { session: 'none', name: '', phone: '', draft: '', launches: 0 };
  try {
    if (!saved.exists) return empty;
    return { ...empty, ...JSON.parse(saved.textSync()) };
  } catch {
    return empty;
  }
}

let state: State = {
  ...load(),
  cart: [],
  orders: 0,
  points: 0,
  popups: [],
  toast: null,
  units: 'Metric',
  publicProfile: false,
  email: '',
  bio: '',
  pin: '',
  push: true,
  emails: false,
  promo: null,
  promoTries: 0,
  onboarded: false,
};
state.launches += 1;

const listeners = new Set<() => void>();

function persist() {
  const { session, name, phone, draft, launches } = state;
  try {
    saved.write(JSON.stringify({ session, name, phone, draft, launches }));
  } catch {}
}
persist();

export function getState(): State {
  return state;
}

export function setState(patch: Partial<State> | ((s: State) => Partial<State>)) {
  state = { ...state, ...(typeof patch === 'function' ? patch(state) : patch) };
  persist();
  listeners.forEach((l) => l());
}

export function useStore<T>(select: (s: State) => T): T {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => select(state),
  );
}

let toastId = 0;
export function toast(text: string) {
  const id = ++toastId;
  setState({ toast: { text, id } });
  setTimeout(() => {
    if (state.toast?.id === id) setState({ toast: null });
  }, 2000);
}

// ---- remembered account (keychain) ----

const REMEMBERED = 'remembered-account';

export async function rememberedName(): Promise<string | null> {
  try {
    return await SecureStore.getItemAsync(REMEMBERED);
  } catch {
    return null;
  }
}

export async function remember(name: string | null) {
  try {
    if (name) await SecureStore.setItemAsync(REMEMBERED, name);
    else await SecureStore.deleteItemAsync(REMEMBERED);
  } catch {}
}

// ---- after an order: the popups an app shows "sometimes" ----

// The first order asks for a rating (1.2 s after the confirmation closes), then unlocks a
// badge once the rating prompt is gone; the second asks for a survey after 2 s.
export function orderClosed() {
  const n = state.orders;
  if (n === 1) setTimeout(() => setState((s) => ({ popups: [...s.popups, 'rate'] })), 1200);
  if (n === 2) setTimeout(() => setState((s) => ({ popups: [...s.popups, 'survey'] })), 2000);
}

export function closePopup(p: Popup) {
  setState((s) => ({ popups: s.popups.filter((x) => x !== p) }));
  if (p === 'rate') setTimeout(() => setState((s) => ({ popups: [...s.popups, 'badge'] })), 800);
}
