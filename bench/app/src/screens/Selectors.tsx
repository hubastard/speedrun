// Selectors: elements alike but for where they are (index, below, rightOf, childOf,
// containsChild), and elements told apart by their state (enabled, selected, checked,
// focused) or their size.
import React, { useState } from 'react';
import { Pressable, ScrollView, Text, TextInput, View } from 'react-native';

import { Body, Button, Checkbox, Chip, Gap, s, Screen, useColors } from '../ui';

const PLANS = [
  { id: 'basic', name: 'Basic', price: '$5' },
  { id: 'plus', name: 'Plus', price: '$10' },
  { id: 'pro', name: 'Pro', price: '$15' },
];

export function Selectors() {
  const c = useColors();
  const [result, setResult] = useState('Nothing chosen');
  const [item, setItem] = useState<number | null>(null);
  const [period, setPeriod] = useState('Week');
  const [notify, setNotify] = useState(true);
  const [hide, setHide] = useState(false);
  const [slow, setSlow] = useState('Slow button: idle');
  return (
    <Screen title="Selectors">
      <Text testID="selector-result" style={{ color: c.text, fontSize: 18, fontWeight: '700' }}>{result}</Text>
      {/* At the top: lower down, the keyboard it brings up would cover it. */}
      <TextInput testID="focus-field" placeholder="Focus me" placeholderTextColor={c.muted} style={[s.field, { color: c.text, borderColor: c.border, marginTop: 8 }]} />
      <Gap />
      {/* Each plan in a scroll view: iOS's accessibility tree puts a plain view's content
          beside it, not under it, so childOf and containsChild need a real container. */}
      {PLANS.map((p) => (
        <ScrollView key={p.id} testID={`plan-${p.id}`} scrollEnabled={false} style={[s.card, { backgroundColor: c.card }]} contentContainerStyle={{ flexDirection: 'row', alignItems: 'center' }}>
          <View style={{ flex: 1 }}>
            <Text style={{ color: c.text, fontWeight: '800', fontSize: 18 }}>{p.name}</Text>
            <Text style={{ color: c.muted }}>{p.price}</Text>
          </View>
          <Button title="Choose" kind="secondary" onPress={() => setResult(`Chose ${p.name}`)} />
        </ScrollView>
      ))}
      <Text style={[s.label, { color: c.muted }]}>Items</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        {[1, 2, 3, 4, 5, 6].map((i) => (
          <Pressable key={i} accessibilityRole="button" onPress={() => setItem(i)} style={{ width: '30%', padding: 14, borderRadius: 10, backgroundColor: c.card, alignItems: 'center' }}>
            <Text style={{ color: c.text }}>Item</Text>
          </Pressable>
        ))}
      </View>
      <Text testID="index-result" style={{ color: c.text, marginTop: 8 }}>{item ? `Picked item ${item}` : 'No item picked'}</Text>
      <Gap />
      <Text style={[s.label, { color: c.muted }]}>States</Text>
      <View style={{ flexDirection: 'row', gap: 10 }}>
        <Button testID="locked" title="Locked" disabled onPress={() => setResult('Locked was tapped')} />
        <Button testID="open-button" title="Open" onPress={() => setResult('Open was tapped')} />
      </View>
      <View style={{ flexDirection: 'row' }}>
        {['Day', 'Week', 'Month'].map((p) => <Chip key={p} testID={`period-${p}`} label={p} selected={p === period} onPress={() => setPeriod(p)} />)}
      </View>
      <Body testID="period-result">{`Showing: ${period}`}</Body>
      <Checkbox testID="notify-me" label="Notify me" checked={notify} onChange={setNotify} />
      <Checkbox testID="hide-me" label="Hide me" checked={hide} onChange={setHide} />
      <Gap />
      <Text style={[s.label, { color: c.muted }]}>Sizes</Text>
      <View style={{ flexDirection: 'row', gap: 16, alignItems: 'center' }}>
        <View testID="box-square" accessible accessibilityLabel="Square" style={{ width: 100, height: 100, backgroundColor: c.accent, borderRadius: 8 }} />
        <View testID="box-wide" accessible accessibilityLabel="Wide" style={{ width: 200, height: 50, backgroundColor: c.ok, borderRadius: 8 }} />
      </View>
      <Gap />
      <Button
        testID="slow-button"
        kind="secondary"
        title="Slow button"
        onPress={() => {
          setSlow('Slow button: working');
          setTimeout(() => setSlow('Slow button: done'), 1200);
        }}
      />
      <Body testID="slow-result">{slow}</Body>
    </Screen>
  );
}
