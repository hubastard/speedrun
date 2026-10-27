// Inputs and keys: a draft note that survives a restart (not clearState), a field that
// reports Enter and Backspace, a code to copy and a field to paste it in, fields that judge
// random text, whether the keyboard is up, and (Android) a switch that catches the back
// button.
import { useFocusEffect } from '@react-navigation/native';
import React, { useCallback, useEffect, useState } from 'react';
import { BackHandler, Keyboard, Switch, Text, View } from 'react-native';

import { setState, useStore } from '../store';
import { Field, Gap, s, Screen, useColors } from '../ui';

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export function Inputs() {
  const c = useColors();
  const draft = useStore((st) => st.draft);
  const [key, setKey] = useState('');
  const [submitted, setSubmitted] = useState('');
  const [backspaces, setBackspaces] = useState(0);
  const [paste, setPaste] = useState('');
  const [rand, setRand] = useState<Record<string, string>>({});
  const [keyboard, setKeyboard] = useState(false);
  const [catchBack, setCatchBack] = useState(false);
  const [backs, setBacks] = useState(0);

  useEffect(() => {
    const show = Keyboard.addListener('keyboardDidShow', () => setKeyboard(true));
    const hide = Keyboard.addListener('keyboardDidHide', () => setKeyboard(false));
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);

  useFocusEffect(
    useCallback(() => {
      if (!catchBack) return;
      const sub = BackHandler.addEventListener('hardwareBackPress', () => {
        setBacks((n) => n + 1);
        return true;
      });
      return () => sub.remove();
    }, [catchBack]),
  );

  const r = (k: string) => ({ value: rand[k] ?? '', onChangeText: (t: string) => setRand((x) => ({ ...x, [k]: t })) });
  const words = (t?: string) => (t ? t.trim().split(/\s+/).length : 0);

  return (
    <Screen title="Inputs and keys">
      <Text testID="keyboard-state" style={[s.body, { color: c.text }]}>{`Keyboard: ${keyboard ? 'shown' : 'hidden'}`}</Text>
      <Gap />
      <Field testID="note-input" label="Draft note (kept across restarts)" value={draft} onChangeText={(t) => setState({ draft: t })} />
      <Field
        testID="key-input"
        label="Press Enter or Backspace here"
        returnKeyType="done"
        value={key}
        onChangeText={setKey}
        onSubmitEditing={() => setSubmitted(key)}
        onKeyPress={(e) => {
          if (e.nativeEvent.key === 'Backspace') setBackspaces((n) => n + 1);
        }}
      />
      <Text testID="submitted" style={[s.body, { color: c.text }]}>{`Submitted: ${submitted || 'nothing'}`}</Text>
      <Text testID="backspaces" style={[s.body, { color: c.text }]}>{`Backspaces: ${backspaces}`}</Text>
      <Gap />
      <Text testID="copy-source" style={[s.body, { color: c.text, fontWeight: '700' }]}>SPEED-4821</Text>
      <Field testID="paste-input" label="Paste here" autoCapitalize="characters" value={paste} onChangeText={setPaste} />
      <Text testID="paste-result" style={[s.body, { color: c.text }]}>{paste === 'SPEED-4821' ? 'Pasted the code' : 'No code yet'}</Text>
      <Gap />
      <Text style={[s.label, { color: c.muted }]}>Random input</Text>
      <Field testID="rand-text" placeholder="Text" {...r('text')} />
      <Field testID="rand-number" placeholder="Number" keyboardType="number-pad" {...r('number')} />
      <Field testID="rand-email" placeholder="Email" keyboardType="email-address" autoCapitalize="none" autoCorrect={false} {...r('email')} />
      <Field testID="rand-name" placeholder="Person name" autoCorrect={false} {...r('name')} />
      <Field testID="rand-city" placeholder="City" autoCorrect={false} {...r('city')} />
      <Field testID="rand-country" placeholder="Country" autoCorrect={false} {...r('country')} />
      <Field testID="rand-color" placeholder="Color" autoCorrect={false} {...r('color')} />
      <Text testID="rand-check" style={[s.body, { color: c.text }]}>
        {[
          `text ${rand.text?.length ?? 0} chars`,
          `number ${/^\d+$/.test(rand.number ?? '') ? 'digits' : 'not digits'}`,
          `email ${EMAIL.test(rand.email ?? '') ? 'valid' : 'invalid'}`,
          `name ${words(rand.name)} words`,
          `city ${rand.city ? 'set' : 'empty'}`,
          `country ${rand.country ? 'set' : 'empty'}`,
          `color ${rand.color ? 'set' : 'empty'}`,
        ].join(' · ')}
      </Text>
      <Gap />
      <View style={s.row}>
        <Text style={{ color: c.text, flex: 1, fontSize: 16 }}>Catch the back button</Text>
        <Switch testID="catch-back" value={catchBack} onValueChange={setCatchBack} />
      </View>
      <Text testID="back-presses" style={[s.body, { color: c.text }]}>{`Back presses: ${backs}`}</Text>
    </Screen>
  );
}
