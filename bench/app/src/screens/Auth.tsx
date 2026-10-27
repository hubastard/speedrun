// Onboarding (first launch only), sign in with a phone number and a one-time code, or as a
// guest. A remembered account ("Remember me") is kept in the keychain: on iOS it survives
// clearState and the app greets it with "Welcome back".
import { useNavigation, useRoute } from '@react-navigation/native';
import React, { useEffect, useRef, useState } from 'react';
import { FlatList, Keyboard, Text, TextInput, useWindowDimensions, View } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withRepeat, withSequence, withTiming } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { remember, rememberedName, setState } from '../store';
import { Body, Button, Checkbox, Field, Gap, Screen, Spinner, Title, useColors } from '../ui';

const PAGES = [
  { title: 'Discover', body: 'Find things you love from people nearby.' },
  { title: 'Collect', body: 'Save your favorites and get notified when prices drop.' },
  { title: 'Share', body: 'Send your finds to friends in one tap.' },
];

export function Onboarding() {
  const nav = useNavigation<any>();
  const c = useColors();
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const list = useRef<FlatList>(null);
  const [page, setPage] = useState(0);
  const last = page === PAGES.length - 1;
  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top, paddingBottom: insets.bottom + 16 }}>
      <View style={{ alignItems: 'flex-end', padding: 12 }}>
        <Text testID="onboarding-skip" accessibilityRole="button" onPress={() => leave(nav)} style={{ color: c.accent, fontSize: 17 }}>Skip</Text>
      </View>
      <FlatList
        ref={list}
        testID="onboarding-pager"
        data={PAGES}
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        keyExtractor={(p) => p.title}
        onMomentumScrollEnd={(e) => setPage(Math.round(e.nativeEvent.contentOffset.x / width))}
        renderItem={({ item, index }) => (
          <View style={{ width, padding: 32, justifyContent: 'center' }}>
            <Floating index={index} />
            <Title>{item.title}</Title>
            <Body muted>{item.body}</Body>
          </View>
        )}
      />
      <Text testID="onboarding-page" style={{ textAlign: 'center', color: c.muted }}>{`Page ${page + 1} of ${PAGES.length}`}</Text>
      <View style={{ paddingHorizontal: 24 }}>
        <Button
          testID={last ? 'get-started' : 'onboarding-next'}
          title={last ? 'Get started' : 'Next'}
          onPress={() => {
            if (last) leave(nav);
            else {
              list.current?.scrollToIndex({ index: page + 1 });
              setPage(page + 1);
            }
          }}
        />
      </View>
    </View>
  );
}

function leave(nav: any) {
  nav.replace('SignIn');
  setState({ onboarded: true });
}

// The page's illustration, bobbing up and down forever.
function Floating({ index }: { index: number }) {
  const c = useColors();
  const y = useSharedValue(0);
  useEffect(() => {
    y.value = withRepeat(withSequence(withTiming(-14, { duration: 900 }), withTiming(0, { duration: 900 })), -1);
  }, [y]);
  const bob = useAnimatedStyle(() => ({ transform: [{ translateY: y.value }] }));
  return (
    <Animated.View
      accessible
      accessibilityLabel={`Illustration ${index + 1}`}
      style={[{ alignSelf: 'center', width: 160, height: 160, borderRadius: 40, backgroundColor: c.accent, marginBottom: 40, opacity: 0.85 }, bob]}
    />
  );
}

// (555) 010-1234 as the digits come.
function formatPhone(digits: string): string {
  const d = digits.slice(0, 10);
  if (d.length <= 3) return d;
  if (d.length <= 6) return `(${d.slice(0, 3)}) ${d.slice(3)}`;
  return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
}

export function SignIn() {
  const nav = useNavigation<any>();
  const [remembered, setRemembered] = useState<string | null | undefined>(undefined);
  const [digits, setDigits] = useState('');
  const [keep, setKeep] = useState(false);
  const [sending, setSending] = useState(false);
  useEffect(() => {
    rememberedName().then(setRemembered);
  }, []);

  if (remembered === undefined) return <Screen title="Sign in" back={false}><Spinner /></Screen>;
  if (remembered) {
    return (
      <Screen title="Sign in" back={false}>
        <Title>{`Welcome back, ${remembered}!`}</Title>
        <Body muted>Pick up where you left off.</Body>
        <Gap h={24} />
        <Button testID="continue-remembered" title={`Continue as ${remembered}`} onPress={() => signedIn(remembered)} />
        <Button
          testID="use-another"
          kind="secondary"
          title="Use another account"
          onPress={() => {
            remember(null);
            setRemembered(null);
          }}
        />
      </Screen>
    );
  }
  return (
    <Screen title="Sign in" back={false}>
      <Title>Let's start with your phone number</Title>
      <Body muted>We'll text you a code to sign in.</Body>
      <Gap h={20} />
      <Field
        testID="phone-input"
        label="Phone number"
        placeholder="(555) 010-1234"
        keyboardType="phone-pad"
        value={formatPhone(digits)}
        onChangeText={(t) => setDigits(t.replace(/\D/g, '').slice(0, 10))}
      />
      <Checkbox testID="remember-me" label="Remember me" checked={keep} onChange={setKeep} />
      <Gap />
      {sending ? <Spinner label="Sending code" /> : null}
      <Button
        testID="next"
        title="Next"
        disabled={digits.length < 10 || sending}
        onPress={() => {
          setSending(true);
          setTimeout(() => {
            setSending(false);
            nav.navigate('Code', { phone: formatPhone(digits), keep });
          }, 700);
        }}
      />
      <Button testID="guest" kind="secondary" title="Continue as guest" onPress={() => setState({ session: 'guest', name: 'Guest' })} />
    </Screen>
  );
}

function signedIn(name: string) {
  setState({ session: 'user', name, cart: [], orders: 0, points: 0 });
  // The notification prompt shows a moment after the home screen.
  setTimeout(() => setState((s) => ({ popups: [...s.popups, 'notify'] })), 700);
}

const CODE = '123456';

// One field for the six digits, drawn as six boxes (what code-entry libraries do): the field
// covers the boxes, its text hidden, so a tap anywhere focuses it.
export function Code() {
  const route = useRoute<any>();
  const c = useColors();
  const input = useRef<TextInput>(null);
  const [code, setCode] = useState('');
  const [verifying, setVerifying] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resendIn, setResendIn] = useState(30);
  const shake = useSharedValue(0);

  useEffect(() => {
    const t = setInterval(() => setResendIn((n) => Math.max(0, n - 1)), 1000);
    return () => clearInterval(t);
  }, []);

  function type(text: string) {
    const digits = text.replace(/\D/g, '').slice(0, 6);
    setCode(digits);
    setError(null);
    if (digits.length === 6) verify(digits);
  }

  function verify(entered: string) {
    // The keyboard goes away with the code (on Android it would stay up over the home screen).
    Keyboard.dismiss();
    setVerifying(true);
    setTimeout(() => {
      setVerifying(false);
      if (entered === CODE) {
        if (route.params?.keep) remember('Alex');
        signedIn('Alex');
      } else {
        setError('Wrong code, try again');
        shake.value = withSequence(withTiming(12, { duration: 50 }), withTiming(-12, { duration: 50 }), withTiming(8, { duration: 50 }), withTiming(0, { duration: 50 }));
        setCode('');
      }
    }, 900);
  }

  const shaking = useAnimatedStyle(() => ({ transform: [{ translateX: shake.value }] }));
  return (
    <Screen title="Verify">
      <Title>Enter the code</Title>
      <Body muted testID="code-sent-to">{`Sent to ${route.params?.phone ?? ''}`}</Body>
      <Gap h={20} />
      <Animated.View style={shaking}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
          {Array.from({ length: 6 }, (_, i) => (
            <View
              key={i}
              style={{ width: 48, height: 56, borderWidth: 2, borderRadius: 10, borderColor: error ? c.danger : i === code.length ? c.accent : c.border, alignItems: 'center', justifyContent: 'center' }}
            >
              <Text testID={`code-digit-${i}`} style={{ fontSize: 24, color: c.text }}>{code[i] ?? ''}</Text>
            </View>
          ))}
        </View>
        <TextInput
          ref={input}
          testID="code-input"
          accessibilityLabel="Code"
          autoFocus
          keyboardType="number-pad"
          textContentType="oneTimeCode"
          maxLength={6}
          caretHidden
          value={code}
          onChangeText={type}
          // Android draws the text in spite of the transparent color: a 1-point font hides it.
          style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, color: 'transparent', backgroundColor: 'transparent', fontSize: 1 }}
        />
      </Animated.View>
      <Gap />
      {error ? <Text testID="code-error" style={{ color: c.danger }}>{error}</Text> : null}
      {verifying ? <Spinner label="Verifying" /> : null}
      <Text testID="resend" style={{ color: c.muted, marginTop: 12 }}>{resendIn > 0 ? `Resend code in ${resendIn}s` : 'Resend code'}</Text>
    </Screen>
  );
}
