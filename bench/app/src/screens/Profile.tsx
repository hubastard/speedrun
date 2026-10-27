// Profile: stats, an edit form (validation on blur, a sticky Save), settings (switches, a
// native confirmation alert, a long list ending with the version), a PIN set on a keypad,
// and sign out behind a native alert.
import { useNavigation } from '@react-navigation/native';
import React, { useRef, useState } from 'react';
import { Alert, Switch, Text, useColorScheme, View } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withSequence, withTiming } from 'react-native-reanimated';

import { remember, setState, toast, useStore } from '../store';
import { Body, Button, Checkbox, CountUp, Field, Gap, Radio, Row, s, Screen, Title, useColors } from '../ui';

export function Profile() {
  const c = useColors();
  const nav = useNavigation<any>();
  const name = useStore((st) => st.name);
  const orders = useStore((st) => st.orders);
  const points = useStore((st) => st.points);
  return (
    <Screen title="Profile" back={false}>
      <View style={{ alignItems: 'center', marginBottom: 16 }}>
        <View style={{ width: 80, height: 80, borderRadius: 40, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ color: c.accentText, fontSize: 32, fontWeight: '800' }}>{name[0] ?? '?'}</Text>
        </View>
        <Title testID="profile-name">{name}</Title>
        <View style={{ flexDirection: 'row', gap: 32 }}>
          <View style={{ alignItems: 'center' }}>
            <Text testID="profile-orders" style={{ color: c.text, fontSize: 28, fontWeight: '700' }}>{orders}</Text>
            <Body muted>Orders</Body>
          </View>
          <View style={{ alignItems: 'center' }}>
            <CountUp testID="profile-points" to={points} />
            <Body muted>Points</Body>
          </View>
        </View>
      </View>
      <Row testID="edit-profile" title="Edit profile" onPress={() => nav.navigate('EditProfile')} />
      <Row testID="settings" title="Settings" onPress={() => nav.navigate('Settings')} />
      <Row testID="security" title="Security" detail="PIN" onPress={() => nav.navigate('Pin')} />
      <Gap h={24} />
      <Button
        testID="sign-out"
        kind="danger"
        title="Sign out"
        onPress={() =>
          Alert.alert('Sign out?', 'You will need a new code to sign back in.', [
            { text: 'Cancel', style: 'cancel' },
            {
              text: 'Yes, sign out',
              style: 'destructive',
              onPress: () => {
                remember(null);
                setState({ session: 'none', name: '', cart: [], popups: [] });
              },
            },
          ])
        }
      />
    </Screen>
  );
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export function EditProfile() {
  const c = useColors();
  const nav = useNavigation<any>();
  const st = useStore((x) => x);
  const [name, setName] = useState(st.name);
  const [email, setEmail] = useState(st.email);
  const [bio, setBio] = useState(st.bio);
  const [units, setUnits] = useState(st.units);
  const [pub, setPub] = useState(st.publicProfile);
  const [touched, setTouched] = useState(false);
  const emailError = touched && email !== '' && !EMAIL.test(email) ? 'Enter a valid email' : null;
  return (
    <Screen
      title="Edit profile"
      footer={
        <Button
          testID="save-profile"
          title="Save"
          disabled={!name.trim() || !!emailError}
          onPress={() => {
            setState({ name: name.trim(), email, bio, units, publicProfile: pub });
            toast('Profile saved');
            nav.goBack();
          }}
        />
      }
    >
      <Field testID="profile-name-input" label="Name" value={name} onChangeText={setName} />
      <Field testID="profile-email-input" label="Email" keyboardType="email-address" autoCapitalize="none" autoCorrect={false} value={email} onChangeText={setEmail} onBlur={() => setTouched(true)} error={emailError} />
      <Field testID="bio-input" label="Bio" multiline value={bio} onChangeText={setBio} style={{ height: 100, textAlignVertical: 'top' }} />
      <Text style={[s.label, { color: c.muted }]}>Units</Text>
      <Radio testID="units-metric" label="Metric" selected={units === 'Metric'} onPress={() => setUnits('Metric')} />
      <Radio testID="units-imperial" label="Imperial" selected={units === 'Imperial'} onPress={() => setUnits('Imperial')} />
      <Checkbox testID="public-profile" label="Show my profile publicly" checked={pub} onChange={setPub} />
      <Gap />
      <Body muted testID="saved-summary">{`Saved: ${st.units}, ${st.publicProfile ? 'public' : 'private'}${st.email ? `, ${st.email}` : ''}`}</Body>
    </Screen>
  );
}

export function Settings() {
  const c = useColors();
  const scheme = useColorScheme();
  const push = useStore((x) => x.push);
  const emails = useStore((x) => x.emails);
  return (
    <Screen title="Settings">
      <View style={s.row}>
        <Text style={{ color: c.text, flex: 1, fontSize: 16 }}>Push notifications</Text>
        <Switch testID="switch-push" value={push} onValueChange={(v) => setState({ push: v })} />
      </View>
      <View style={s.row}>
        <Text style={{ color: c.text, flex: 1, fontSize: 16 }}>Email updates</Text>
        <Switch testID="switch-emails" value={emails} onValueChange={(v) => setState({ emails: v })} />
      </View>
      <Body testID="appearance">{`Appearance: ${scheme === 'dark' ? 'Dark' : 'Light'}`}</Body>
      <Gap />
      <Button
        testID="clear-cache"
        kind="secondary"
        title="Clear cache"
        onPress={() =>
          Alert.alert('Clear cache?', 'This removes 24 MB of saved images.', [
            { text: 'Cancel', style: 'cancel' },
            { text: 'Clear', style: 'destructive', onPress: () => toast('Cache cleared') },
          ])
        }
      />
      {Array.from({ length: 25 }, (_, i) => <Row key={i} testID={`setting-${i + 1}`} title={`Setting ${i + 1}`} detail={i % 2 ? 'On' : 'Off'} />)}
      <Gap />
      <Text testID="version" style={{ color: c.muted, textAlign: 'center' }}>Version 1.0.0</Text>
    </Screen>
  );
}

export function Pin() {
  const c = useColors();
  const nav = useNavigation<any>();
  const [first, setFirst] = useState<string | null>(null);
  const [digits, setDigits] = useState('');
  const typed = useRef('');
  const [error, setError] = useState<string | null>(null);
  const shake = useSharedValue(0);
  const shaking = useAnimatedStyle(() => ({ transform: [{ translateX: shake.value }] }));

  function press(key: string) {
    setError(null);
    if (key === 'del') {
      typed.current = typed.current.slice(0, -1);
      setDigits(typed.current);
      return;
    }
    if (typed.current.length >= 4) return;
    const next = typed.current + key;
    typed.current = next;
    setDigits(next);
    if (next.length < 4) return;
    setTimeout(() => {
      typed.current = '';
      if (first === null) {
        setFirst(next);
        setDigits('');
      } else if (first === next) {
        setState({ pin: next });
        toast('PIN set');
        nav.goBack();
      } else {
        setError("PINs don't match");
        shake.value = withSequence(withTiming(12, { duration: 50 }), withTiming(-12, { duration: 50 }), withTiming(0, { duration: 50 }));
        setFirst(null);
        setDigits('');
      }
    }, 250);
  }

  return (
    <Screen title="Security">
      <Title testID="pin-title">{first === null ? 'Create a PIN' : 'Confirm your PIN'}</Title>
      <Animated.View testID="pin-dots" accessible accessibilityLabel={`${digits.length} of 4 digits`} style={[{ flexDirection: 'row', justifyContent: 'center', gap: 16, marginVertical: 24 }, shaking]}>
        {[0, 1, 2, 3].map((i) => (
          <View key={i} style={{ width: 18, height: 18, borderRadius: 9, borderWidth: 2, borderColor: c.accent, backgroundColor: i < digits.length ? c.accent : 'transparent' }} />
        ))}
      </Animated.View>
      {error ? <Text testID="pin-error" style={{ color: c.danger, textAlign: 'center' }}>{error}</Text> : null}
      <Keypad onPress={press} />
    </Screen>
  );
}

// A custom keypad: key-0 … key-9, key-del.
export function Keypad({ onPress }: { onPress: (key: string) => void }) {
  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'del'];
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center' }}>
      {keys.map((k, i) =>
        k === '' ? (
          <View key={i} style={{ width: '30%', margin: '1.5%' }} />
        ) : (
          <View key={i} style={{ width: '30%', margin: '1.5%' }}>
            <Button testID={`key-${k}`} kind="secondary" title={k === 'del' ? '⌫' : k} onPress={() => onPress(k)} />
          </View>
        ),
      )}
    </View>
  );
}
