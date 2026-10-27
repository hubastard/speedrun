// The lab: one screen per thing a flow can do, each showing what happened as text a flow
// asserts. Animations: a scene per kind of motion, each with a Tap button and its count.
import { useNavigation, useRoute } from '@react-navigation/native';
import LottieView from 'lottie-react-native';
import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Animated as RNAnimated, Easing as RNEasing, FlatList, Text, useWindowDimensions, View } from 'react-native';
import Animated, { Easing, useAnimatedStyle, useSharedValue, withRepeat, withTiming } from 'react-native-reanimated';

import { orderClosed, setState } from '../store';
import { Body, Button, Confetti, Gap, Marquee, Row, s, Screen, Shimmer, useColors } from '../ui';

export function Lab() {
  const nav = useNavigation<any>();
  return (
    <Screen title="Lab" back={false}>
      <Body muted>Everything a flow can do, one screen each.</Body>
      <Gap />
      <Row testID="lab-animations" title="Animations" onPress={() => nav.navigate('Animations')} />
      <Row testID="lab-gestures" title="Gestures" onPress={() => nav.navigate('Gestures')} />
      <Row testID="lab-drag" title="Drag and scroll" onPress={() => nav.navigate('Drag')} />
      <Row testID="lab-selectors" title="Selectors" onPress={() => nav.navigate('Selectors')} />
      <Row testID="lab-inputs" title="Inputs and keys" onPress={() => nav.navigate('Inputs')} />
      <Row testID="lab-device" title="Device" onPress={() => nav.navigate('Device')} />
      {/* The popups an order brings, without the order. */}
      <Row testID="lab-popups-first" title="First order popups" onPress={() => { setState({ orders: 1 }); orderClosed(); }} />
      <Row testID="lab-popups-second" title="Second order popup" onPress={() => { setState({ orders: 2 }); orderClosed(); }} />
    </Screen>
  );
}

export const SCENES: { id: string; title: string; about: string }[] = [
  { id: 'still', title: 'Still', about: 'Nothing moves: the baseline.' },
  { id: 'reanimated', title: 'Reanimated loop', about: 'A box sliding back and forth on the UI thread, forever.' },
  { id: 'native-driver', title: 'Animated native loop', about: 'Animated.loop with the native driver: a box sliding forever.' },
  { id: 'js-driver', title: 'Animated JS loop', about: 'Animated.loop without the native driver: a bar resized from JavaScript every frame.' },
  { id: 'lottie', title: 'Lottie', about: 'A Lottie animation looping forever.' },
  { id: 'spinner', title: 'Spinner', about: 'A system activity indicator.' },
  { id: 'ticker', title: 'Ticker', about: 'A price changing every 100 ms.' },
  { id: 'counter', title: 'Frame counter', about: 'A number changing on every frame, forever.' },
  { id: 'marquee', title: 'Marquee', about: 'A line of text sliding forever.' },
  { id: 'shimmer', title: 'Skeleton', about: 'Skeleton blocks with a shimmer, forever.' },
  { id: 'carousel', title: 'Carousel', about: 'Pages turning on their own every 2 s.' },
  { id: 'confetti', title: 'Confetti', about: 'Each tap sets off 40 falling particles.' },
  { id: 'progress', title: 'Progress', about: 'A progress bar filling over 4 s, again and again.' },
  { id: 'delayed', title: 'Delayed button', about: 'The Tap button turns on 1.5 s after the screen opens.' },
  { id: 'shift', title: 'Layout shift', about: 'A banner appears after 1 s and pushes the Tap button down.' },
  { id: 'busy', title: 'Busy JavaScript', about: 'Each tap blocks the JavaScript thread for 1 s before it counts.' },
];

export function Animations() {
  const nav = useNavigation<any>();
  return (
    <Screen title="Animations">
      {SCENES.map((sc) => <Row key={sc.id} testID={`scene-${sc.id}`} title={sc.title} onPress={() => nav.navigate('Scene', { scene: sc.id })} />)}
    </Screen>
  );
}

export function Scene() {
  const c = useColors();
  const route = useRoute<any>();
  const id: string = route.params?.scene ?? 'still';
  const scene = SCENES.find((x) => x.id === id) ?? SCENES[0];
  const [taps, setTaps] = useState(0);
  const [bursts, setBursts] = useState(0);
  const [enabled, setEnabled] = useState(id !== 'delayed');
  const [banner, setBanner] = useState(false);
  useEffect(() => {
    if (id === 'delayed') {
      const t = setTimeout(() => setEnabled(true), 1500);
      return () => clearTimeout(t);
    }
    if (id === 'shift') {
      const t = setTimeout(() => setBanner(true), 1000);
      return () => clearTimeout(t);
    }
  }, [id]);
  return (
    <View style={{ flex: 1 }}>
      <Screen title={scene.title}>
        <Body muted>{scene.about}</Body>
        <Gap />
        {banner ? (
          <View testID="shift-banner" style={[s.card, { backgroundColor: c.accent, height: 140, justifyContent: 'center' }]}>
            <Text style={{ color: c.accentText, fontSize: 18, fontWeight: '800' }}>A banner that came late</Text>
          </View>
        ) : null}
        <Motion id={id} />
        <Gap h={24} />
        <Button
          testID="lab-tap"
          title="Tap"
          disabled={!enabled}
          onPress={() => {
            if (id === 'busy') {
              const end = Date.now() + 1000;
              while (Date.now() < end) {}
            }
            if (id === 'confetti') setBursts((n) => n + 1);
            setTaps((n) => n + 1);
          }}
        />
        <Text testID="lab-count" style={{ color: c.text, fontSize: 20, fontWeight: '700', textAlign: 'center' }}>{`Taps: ${taps}`}</Text>
      </Screen>
      {id === 'confetti' && bursts > 0 ? <Confetti key={bursts} /> : null}
    </View>
  );
}

function Motion({ id }: { id: string }) {
  switch (id) {
    case 'reanimated': return <ReanimatedLoop />;
    case 'native-driver': return <AnimatedLoop native />;
    case 'js-driver': return <AnimatedLoop native={false} />;
    case 'lottie': return <LottieView testID="lottie" source={require('../../assets/spinner.json')} autoPlay loop style={{ width: 120, height: 120, alignSelf: 'center' }} />;
    case 'spinner': return <ActivityIndicator testID="spinner" size="large" />;
    case 'ticker': return <Ticker every={100} />;
    case 'counter': return <FrameCounter />;
    case 'marquee': return <Marquee testID="marquee" text="Breaking: everything keeps moving   ·   Breaking: everything keeps moving   ·   Breaking" />;
    case 'shimmer': return <View>{[0, 1, 2, 3].map((k) => <Shimmer key={k} height={28} />)}</View>;
    case 'carousel': return <AutoCarousel />;
    case 'progress': return <ProgressLoop />;
    default: return null;
  }
}

function ReanimatedLoop() {
  const c = useColors();
  const x = useSharedValue(0);
  useEffect(() => {
    x.value = withRepeat(withTiming(220, { duration: 1200, easing: Easing.inOut(Easing.quad) }), -1, true);
  }, [x]);
  const move = useAnimatedStyle(() => ({ transform: [{ translateX: x.value }] }));
  return (
    <Animated.View testID="moving-box" accessible accessibilityLabel="Moving box" style={[{ width: 80, height: 80, borderRadius: 16, backgroundColor: c.accent }, move]} />
  );
}

function AnimatedLoop({ native }: { native: boolean }) {
  const c = useColors();
  const v = useRef(new RNAnimated.Value(0)).current;
  useEffect(() => {
    const loop = RNAnimated.loop(
      RNAnimated.sequence([
        RNAnimated.timing(v, { toValue: 1, duration: 1200, easing: RNEasing.inOut(RNEasing.quad), useNativeDriver: native }),
        RNAnimated.timing(v, { toValue: 0, duration: 1200, easing: RNEasing.inOut(RNEasing.quad), useNativeDriver: native }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [native, v]);
  if (native) {
    const x = v.interpolate({ inputRange: [0, 1], outputRange: [0, 220] });
    return <RNAnimated.View testID="moving-box" accessible accessibilityLabel="Moving box" style={{ width: 80, height: 80, borderRadius: 16, backgroundColor: c.accent, transform: [{ translateX: x }] }} />;
  }
  const width = v.interpolate({ inputRange: [0, 1], outputRange: [40, 300] });
  return (
    <RNAnimated.View testID="growing-bar" accessible accessibilityLabel="Growing bar" style={{ height: 40, borderRadius: 8, backgroundColor: c.accent, width }} />
  );
}

function Ticker({ every }: { every: number }) {
  const c = useColors();
  const [price, setPrice] = useState(100);
  useEffect(() => {
    let k = 0;
    const t = setInterval(() => {
      k += 1;
      setPrice(100 + ((k * 37) % 100) / 10);
    }, every);
    return () => clearInterval(t);
  }, [every]);
  return <Text testID="ticker" style={{ color: c.text, fontSize: 32, fontWeight: '700' }}>{`$${price.toFixed(2)}`}</Text>;
}

function FrameCounter() {
  const c = useColors();
  const [n, setN] = useState(0);
  useEffect(() => {
    let frame = 0;
    const tick = () => {
      setN((x) => x + 1);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, []);
  return <Text testID="frame-counter" style={{ color: c.text, fontSize: 32, fontWeight: '700' }}>{`Frame ${n}`}</Text>;
}

function AutoCarousel() {
  const c = useColors();
  const { width } = useWindowDimensions();
  const w = width - 32;
  const list = useRef<FlatList>(null);
  const [page, setPage] = useState(0);
  useEffect(() => {
    const t = setInterval(() => {
      setPage((p) => {
        const next = (p + 1) % 4;
        list.current?.scrollToOffset({ offset: next * w, animated: true });
        return next;
      });
    }, 2000);
    return () => clearInterval(t);
  }, [w]);
  return (
    <View>
      <FlatList
        ref={list}
        testID="carousel"
        horizontal
        pagingEnabled
        scrollEnabled={false}
        data={[0, 1, 2, 3]}
        keyExtractor={(i) => String(i)}
        renderItem={({ item }) => (
          <View style={{ width: w, height: 140, borderRadius: 14, backgroundColor: ['#c7d2fe', '#fde68a', '#bbf7d0', '#fecaca'][item], justifyContent: 'center', alignItems: 'center' }}>
            <Text style={{ color: '#111827', fontSize: 20, fontWeight: '700' }}>{`Slide ${item + 1}`}</Text>
          </View>
        )}
      />
      <Text testID="carousel-page" style={{ color: c.muted, textAlign: 'center' }}>{`Slide ${page + 1} of 4`}</Text>
    </View>
  );
}

function ProgressLoop() {
  const c = useColors();
  const p = useSharedValue(0);
  useEffect(() => {
    p.value = withRepeat(withTiming(1, { duration: 4000, easing: Easing.linear }), -1);
  }, [p]);
  const fill = useAnimatedStyle(() => ({ width: `${p.value * 100}%` }));
  return (
    <View testID="progress" accessible accessibilityLabel="Progress" style={{ height: 12, borderRadius: 6, backgroundColor: c.border, overflow: 'hidden' }}>
      <Animated.View style={[{ height: 12, backgroundColor: c.accent }, fill]} />
    </View>
  );
}
