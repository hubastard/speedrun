// Gestures: a pad that names the direction it was swiped, a pad that names where it was
// tapped, single / double tap and long press targets; then a slider to drag, a card to drop
// in a zone, a horizontal list, and a long list with sticky section headers.
import { useNavigation } from '@react-navigation/native';
import React, { useState } from 'react';
import { FlatList, Pressable, SectionList, Text, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { runOnJS, useAnimatedStyle, useSharedValue, withSpring } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Body, Button, Header, s, useColors } from '../ui';

export function Gestures() {
  const c = useColors();
  const insets = useSafeAreaInsets();
  const [swipe, setSwipe] = useState('none');
  const [swipes, setSwipes] = useState(0);
  const [tapped, setTapped] = useState('nowhere');
  const [single, setSingle] = useState(0);
  const [double, setDouble] = useState(0);
  const [longs, setLongs] = useState(0);

  const pan = Gesture.Pan()
    .minDistance(20)
    .onEnd((e) => {
      const dir = Math.abs(e.translationX) > Math.abs(e.translationY) ? (e.translationX < 0 ? 'LEFT' : 'RIGHT') : e.translationY < 0 ? 'UP' : 'DOWN';
      runOnJS(setSwipe)(dir);
      runOnJS(setSwipes)(swipes + 1);
    });
  const doubleTap = Gesture.Tap().numberOfTaps(2).maxDelay(300).onEnd((_e, ok) => {
    if (ok) runOnJS(setDouble)(double + 1);
  });
  const singleTap = Gesture.Tap().onEnd((_e, ok) => {
    if (ok) runOnJS(setSingle)(single + 1);
  });
  const longPress = Gesture.LongPress().minDuration(600).onStart(() => {
    runOnJS(setLongs)(longs + 1);
  });

  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title="Gestures" />
      <View style={{ padding: 16, gap: 12 }}>
        <GestureDetector gesture={pan}>
          <View testID="swipe-pad" accessible accessibilityLabel="Swipe pad" collapsable={false} style={[pad(c), { height: 170 }]}>
            <Text style={{ color: c.muted }}>Swipe here</Text>
          </View>
        </GestureDetector>
        <Text testID="swipe-result" style={{ color: c.text }}>{`Last swipe: ${swipe} (${swipes})`}</Text>
        <Pressable
          testID="tap-pad"
          accessibilityLabel="Tap pad"
          onPress={(e) => {
            const { locationX: x, locationY: y } = e.nativeEvent;
            setTapped(`${y < 60 ? 'top' : 'bottom'} ${x < 160 ? 'left' : 'right'}`);
          }}
          style={[pad(c), { height: 120, width: 320, alignSelf: 'center' }]}
        >
          <Text style={{ color: c.muted }}>Tap a corner</Text>
        </Pressable>
        <Text testID="tap-result" style={{ color: c.text }}>{`Tapped ${tapped}`}</Text>
        <View style={{ flexDirection: 'row', gap: 12 }}>
          <GestureDetector gesture={Gesture.Exclusive(doubleTap, singleTap)}>
            <View testID="double-tap-target" accessible accessibilityLabel="Tap target" collapsable={false} style={[pad(c), { flex: 1, height: 80 }]}>
              <Text style={{ color: c.muted }}>Tap or double tap</Text>
            </View>
          </GestureDetector>
          <GestureDetector gesture={longPress}>
            <View testID="long-press-target" accessible accessibilityLabel="Long press target" collapsable={false} style={[pad(c), { flex: 1, height: 80 }]}>
              <Text style={{ color: c.muted }}>Hold me</Text>
            </View>
          </GestureDetector>
        </View>
        <Text testID="tap-counts" style={{ color: c.text }}>{`Single: ${single} · Double: ${double}`}</Text>
        <Text testID="long-press-result" style={{ color: c.text }}>{`Long presses: ${longs}`}</Text>
      </View>
    </View>
  );
}

function pad(c: ReturnType<typeof useColors>) {
  return { borderRadius: 14, borderWidth: 2, borderStyle: 'dashed' as const, borderColor: c.border, backgroundColor: c.card, alignItems: 'center' as const, justifyContent: 'center' as const };
}

const HANDLE = 44;

export function Drag() {
  const c = useColors();
  const nav = useNavigation<any>();
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const track = width - 32;
  const travel = track - HANDLE;
  const [volume, setVolume] = useState(0);
  const [drop, setDrop] = useState('Drag the card into the zone');
  const x = useSharedValue(0);
  const start = useSharedValue(0);
  const slide = Gesture.Pan()
    .onBegin(() => {
      start.value = x.value;
    })
    .onUpdate((e) => {
      x.value = Math.max(0, Math.min(travel, start.value + e.translationX));
      runOnJS(setVolume)(Math.round((x.value / travel) * 100));
    });
  const handle = useAnimatedStyle(() => ({ transform: [{ translateX: x.value }] }));

  // The card follows the finger; let go over the zone (below it) and it stays there.
  const cx = useSharedValue(0);
  const cy = useSharedValue(0);
  const [zoneTop, setZoneTop] = useState(0);
  const [cardTop, setCardTop] = useState(0);
  const dragCard = Gesture.Pan()
    .onUpdate((e) => {
      cx.value = e.translationX;
      cy.value = e.translationY;
    })
    .onEnd((e) => {
      const inZone = cardTop + 30 + e.translationY > zoneTop;
      runOnJS(setDrop)(inZone ? 'Dropped in the zone' : 'Missed the zone');
      if (!inZone) {
        cx.value = withSpring(0);
        cy.value = withSpring(0);
      }
    });
  const card = useAnimatedStyle(() => ({ transform: [{ translateX: cx.value }, { translateY: cy.value }] }));

  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title="Drag and scroll" />
      <View style={{ padding: 16 }}>
        <Text testID="slider-value" style={{ color: c.text, marginBottom: 8 }}>{`Volume: ${volume}`}</Text>
        <View testID="slider-track" style={{ height: HANDLE, borderRadius: HANDLE / 2, backgroundColor: c.card, justifyContent: 'center' }}>
          <GestureDetector gesture={slide}>
            <Animated.View testID="slider-handle" accessible accessibilityLabel="Volume handle" style={[{ width: HANDLE, height: HANDLE, borderRadius: HANDLE / 2, backgroundColor: c.accent }, handle]} />
          </GestureDetector>
        </View>
        <Text style={[s.label, { color: c.muted, marginTop: 16 }]}>Cards</Text>
        <FlatList
          testID="h-list"
          horizontal
          showsHorizontalScrollIndicator={false}
          data={Array.from({ length: 30 }, (_, i) => i + 1)}
          keyExtractor={(i) => String(i)}
          renderItem={({ item }) => (
            <View style={{ width: 110, height: 70, marginRight: 10, borderRadius: 12, backgroundColor: c.card, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ color: c.text, fontWeight: '700' }}>{`Card ${item}`}</Text>
            </View>
          )}
        />
        <Button testID="open-long-list" kind="secondary" title="Open the long list" onPress={() => nav.navigate('LongList')} />
        <Text testID="drop-result" style={{ color: c.text, marginTop: 8 }}>{drop}</Text>
      </View>
      <View style={{ flex: 1, paddingHorizontal: 16 }}>
        <View onLayout={(e) => setCardTop(e.nativeEvent.layout.y)} style={{ height: 70, zIndex: 2 }}>
          <GestureDetector gesture={dragCard}>
            <Animated.View testID="drag-card" accessible accessibilityLabel="Drag me" style={[{ width: 120, height: 60, borderRadius: 12, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }, card]}>
              <Text style={{ color: c.accentText, fontWeight: '700' }}>Drag me</Text>
            </Animated.View>
          </GestureDetector>
        </View>
        <View
          testID="drop-zone"
          onLayout={(e) => setZoneTop(e.nativeEvent.layout.y)}
          style={{ flex: 1, marginTop: 24, marginBottom: 16 + insets.bottom, borderRadius: 14, borderWidth: 2, borderStyle: 'dashed', borderColor: c.accent, alignItems: 'center', justifyContent: 'center' }}
        >
          <Body muted>Drop zone</Body>
        </View>
      </View>
    </View>
  );
}

const SECTIONS = 'ABCDEFGHIJKLMNOPQRST'.split('').map((letter, k) => ({
  title: `Section ${letter}`,
  data: Array.from({ length: 25 }, (_, i) => k * 25 + i + 1),
}));

export function LongList() {
  const c = useColors();
  const insets = useSafeAreaInsets();
  const [picked, setPicked] = useState<number | null>(null);
  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title="Long list" />
      <Text testID="picked-row" style={{ color: c.text, padding: 12 }}>{picked ? `Picked row ${picked}` : 'Pick a row'}</Text>
      <SectionList
        testID="long-list"
        sections={SECTIONS}
        keyExtractor={(i) => String(i)}
        stickySectionHeadersEnabled
        renderSectionHeader={({ section }) => (
          <View style={{ backgroundColor: c.card, paddingVertical: 10, paddingHorizontal: 16 }}>
            <Text style={{ color: c.text, fontWeight: '800' }}>{section.title}</Text>
          </View>
        )}
        renderItem={({ item }) => (
          <Pressable testID={`row-${item}`} accessibilityRole="button" onPress={() => setPicked(item)} style={[s.row, { borderColor: c.border, paddingHorizontal: 16 }]}>
            <Text style={{ color: c.text }}>{`Row ${item}`}</Text>
          </Pressable>
        )}
      />
    </View>
  );
}
