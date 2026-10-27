// Shop: debounced search (Enter submits at once), category chips, a product grid; a product
// page with an auto-advancing photo carousel, color and size pickers, a quantity stepper; a
// cart with swipe-to-remove rows and a promo code that fails once; checkout with a form the
// keyboard covers and a sticky footer; the confirmation with confetti and a count-up.
import { useNavigation, useRoute } from '@react-navigation/native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { FlatList, Pressable, ScrollView, Text, useWindowDimensions, View } from 'react-native';
import ReanimatedSwipeable from 'react-native-gesture-handler/ReanimatedSwipeable';
import Animated, { useAnimatedStyle, useSharedValue, withSequence, withSpring, withTiming } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { CATEGORIES, COLORS, money, product, PRODUCTS, SIZES } from '../data';
import { CartLine, getState, orderClosed, setState, toast, useStore } from '../store';
import {
  Body, Button, Checkbox, Chip, Confetti, CountUp, Field, Gap, Header, Radio, s, Screen, Shimmer, Spinner, Title, useColors,
} from '../ui';

export function CartButton() {
  const c = useColors();
  const nav = useNavigation<any>();
  const count = useStore((st) => st.cart.reduce((n, l) => n + l.qty, 0));
  const bounce = useSharedValue(1);
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    bounce.value = withSequence(withSpring(1.4), withSpring(1));
  }, [count, bounce]);
  const style = useAnimatedStyle(() => ({ transform: [{ scale: bounce.value }] }));
  return (
    <Pressable testID="cart-button" accessibilityRole="button" onPress={() => nav.navigate('Cart')} hitSlop={8}>
      <Animated.Text style={[{ color: c.accent, fontSize: 16, fontWeight: '700' }, style]}>{`Cart (${count})`}</Animated.Text>
    </Pressable>
  );
}

export function Shop() {
  const c = useColors();
  const nav = useNavigation<any>();
  const insets = useSafeAreaInsets();
  const [query, setQuery] = useState('');
  const [applied, setApplied] = useState('');
  const [searching, setSearching] = useState(false);
  const [submitted, setSubmitted] = useState('');
  const [category, setCategory] = useState('All');
  const [wish, setWish] = useState<Record<number, boolean>>({});
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Typing waits 400 ms for a pause, then "asks the server" (500 ms).
  function search(q: string, now = false) {
    setQuery(q);
    if (timer.current) clearTimeout(timer.current);
    const run = () => {
      setSearching(true);
      timer.current = setTimeout(() => {
        setApplied(q.trim());
        setSearching(false);
      }, 500);
    };
    if (now) run();
    else timer.current = setTimeout(run, 400);
  }

  const shown = useMemo(
    () =>
      PRODUCTS.filter(
        (p) => (category === 'All' || p.category === category) && (!applied || p.name.toLowerCase().includes(applied.toLowerCase())),
      ),
    [applied, category],
  );

  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title="Shop" back={false} right={<CartButton />} />
      <View style={{ paddingHorizontal: 16, paddingTop: 12 }}>
        <Field
          testID="search-input"
          placeholder="Search products"
          returnKeyType="search"
          value={query}
          onChangeText={(t) => search(t)}
          onSubmitEditing={() => {
            setSubmitted(query);
            search(query, true);
          }}
        />
      </View>
      <View>
        <ScrollView testID="categories" horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 16 }}>
          {CATEGORIES.map((cat) => (
            <Chip key={cat} testID={`chip-${cat}`} label={cat} selected={cat === category} onPress={() => setCategory(cat)} />
          ))}
        </ScrollView>
      </View>
      {submitted ? <Text testID="submitted-search" style={{ color: c.muted, paddingHorizontal: 16 }}>{`Searched for "${submitted}"`}</Text> : null}
      {searching ? (
        <View style={{ padding: 16 }}>
          <Spinner label="Searching" />
          <Shimmer height={120} />
        </View>
      ) : (
        <FlatList
          testID="products"
          data={shown}
          numColumns={2}
          keyExtractor={(p) => String(p.id)}
          contentContainerStyle={{ padding: 10 }}
          ListEmptyComponent={<Body muted testID="no-results">No products match</Body>}
          ListHeaderComponent={<Text testID="result-count" style={{ color: c.muted, margin: 6 }}>{`${shown.length} products`}</Text>}
          renderItem={({ item }) => (
            <View style={{ flex: 1, margin: 6, borderRadius: 14, backgroundColor: c.card }}>
              <Pressable
                testID={`product-${item.id}`}
                accessibilityRole="button"
                accessibilityLabel={item.name}
                onPress={() => nav.navigate('Product', { id: item.id })}
                style={{ padding: 12 }}
              >
                <View style={{ height: 90, borderRadius: 10, backgroundColor: c.border, marginBottom: 8 }} />
                <Text style={{ color: c.text, fontWeight: '700' }} numberOfLines={1}>{item.name}</Text>
                <Text style={{ color: c.muted }}>{money(item.price)}</Text>
              </Pressable>
              {/* A sibling, not a child: iOS hides what an accessible element contains. */}
              <Pressable
                testID={`wish-${item.id}`}
                accessibilityRole="button"
                accessibilityLabel="Wishlist"
                accessibilityState={{ selected: !!wish[item.id] }}
                onPress={() => setWish((w) => ({ ...w, [item.id]: !w[item.id] }))}
                hitSlop={8}
                style={{ position: 'absolute', right: 10, top: 10 }}
              >
                <Text style={{ fontSize: 20, color: wish[item.id] ? '#ef4444' : c.muted }}>{wish[item.id] ? '♥' : '♡'}</Text>
              </Pressable>
            </View>
          )}
        />
      )}
    </View>
  );
}

export function ProductScreen() {
  const c = useColors();
  const nav = useNavigation<any>();
  const route = useRoute<any>();
  const p = product(Number(route.params?.id ?? 1));
  const [color, setColor] = useState('Black');
  const [size, setSize] = useState<string | null>(null);
  const [qty, setQty] = useState(1);
  const [gift, setGift] = useState(false);
  return (
    <Screen
      title="Product"
      right={<CartButton />}
      footer={
        <View style={{ flexDirection: 'row', gap: 10 }}>
          <Button
            testID="add-to-cart"
            title={size ? 'Add to cart' : 'Pick a size'}
            disabled={!size}
            style={{ flex: 1 }}
            onPress={() => {
              const key = `${p.id}-${size}-${color}-${gift}`;
              setState((st) => {
                const found = st.cart.find((l) => l.key === key);
                const cart: CartLine[] = found
                  ? st.cart.map((l) => (l.key === key ? { ...l, qty: l.qty + qty } : l))
                  : [...st.cart, { key, productId: p.id, size: size!, color, qty, gift }];
                return { cart };
              });
              toast('Added to cart');
            }}
          />
          <Button testID="go-to-cart" kind="secondary" title="Go to cart" onPress={() => nav.navigate('Cart')} />
        </View>
      }
    >
      <Photos />
      <Gap />
      <Title testID="product-name">{p.name}</Title>
      <Text testID="product-price" style={{ color: c.text, fontSize: 20, fontWeight: '700' }}>{money(p.price)}</Text>
      <Text style={{ color: c.muted }}>{`★ ${p.rating} · ${p.reviews} reviews`}</Text>
      <Gap h={16} />
      <Text style={[s.label, { color: c.muted }]}>Color</Text>
      {COLORS.map((col) => <Radio key={col} testID={`color-${col}`} label={col} selected={col === color} onPress={() => setColor(col)} />)}
      <Gap />
      <Text style={[s.label, { color: c.muted }]}>Size</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap' }}>
        {SIZES.map((sz) => <Chip key={sz} testID={`size-${sz}`} label={sz} selected={sz === size} onPress={() => setSize(sz)} />)}
      </View>
      <Gap />
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 16 }}>
        <Button testID="qty-minus" kind="secondary" title="−" disabled={qty <= 1} onPress={() => setQty((n) => Math.max(1, n - 1))} />
        <Text testID="qty-value" style={{ color: c.text, fontSize: 18, fontWeight: '700' }}>{`Qty ${qty}`}</Text>
        <Button testID="qty-plus" kind="secondary" title="+" disabled={qty >= 9} onPress={() => setQty((n) => Math.min(9, n + 1))} />
      </View>
      <Checkbox testID="gift-wrap" label="Gift wrap" checked={gift} onChange={setGift} />
      <Gap h={16} />
      <Text style={[s.label, { color: c.muted }]}>Description</Text>
      <Body>{`The ${p.name} is built for everyday use: light, durable and easy to care for. It ships in recycled packaging and comes with a two-year warranty.`}</Body>
      <Gap h={16} />
      <Text style={[s.label, { color: c.muted }]}>Reviews</Text>
      {Array.from({ length: 10 }, (_, i) => (
        <View key={i} style={[s.card, { backgroundColor: c.card }]}>
          <Text testID={`review-${i + 1}`} style={{ color: c.text, fontWeight: '700' }}>{`Review ${i + 1}`}</Text>
          <Body muted>{i % 2 ? 'Exactly as described, fast shipping.' : 'Great quality for the price. Would buy again.'}</Body>
        </View>
      ))}
    </Screen>
  );
}

// Three photos, paging on their own every 2.5 s, or with a swipe.
function Photos() {
  const c = useColors();
  const { width } = useWindowDimensions();
  const w = width - 32;
  const list = useRef<FlatList>(null);
  const [index, setIndex] = useState(0);
  useEffect(() => {
    const t = setInterval(() => {
      setIndex((i) => {
        const next = (i + 1) % 3;
        list.current?.scrollToOffset({ offset: next * w, animated: true });
        return next;
      });
    }, 2500);
    return () => clearInterval(t);
  }, [w]);
  return (
    <View>
      <FlatList
        ref={list}
        testID="product-photos"
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        data={[0, 1, 2]}
        keyExtractor={(i) => String(i)}
        onMomentumScrollEnd={(e) => setIndex(Math.round(e.nativeEvent.contentOffset.x / w))}
        renderItem={({ item }) => (
          <View style={{ width: w, height: 200, borderRadius: 14, backgroundColor: ['#c7d2fe', '#fde68a', '#bbf7d0'][item], alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ color: '#111827', fontSize: 20, fontWeight: '700' }}>{`Photo ${item + 1}`}</Text>
          </View>
        )}
      />
      <Text testID="photo-index" style={{ color: c.muted, textAlign: 'center', marginTop: 6 }}>{`Photo ${index + 1} of 3`}</Text>
    </View>
  );
}

function lineTotal(l: CartLine): number {
  return product(l.productId).price * l.qty + (l.gift ? 4.99 : 0);
}

export function Cart() {
  const c = useColors();
  const nav = useNavigation<any>();
  const cart = useStore((st) => st.cart);
  const promo = useStore((st) => st.promo);
  const [code, setCode] = useState('');
  const [applying, setApplying] = useState(false);
  const [promoError, setPromoError] = useState<string | null>(null);
  const subtotal = cart.reduce((n, l) => n + lineTotal(l), 0);
  const discount = promo ? subtotal * 0.1 : 0;
  const total = subtotal - discount;

  function setQty(key: string, delta: number) {
    setState((st) => ({ cart: st.cart.map((l) => (l.key === key ? { ...l, qty: Math.max(1, Math.min(9, l.qty + delta)) } : l)) }));
  }

  // The first try fails ("the server" times out), as networks do: retry it.
  function apply() {
    setApplying(true);
    setPromoError(null);
    setTimeout(() => {
      setApplying(false);
      const tries = getState().promoTries;
      setState({ promoTries: tries + 1 });
      if (tries === 0) setPromoError("Couldn't reach the server, try again");
      else if (code.trim().toUpperCase() !== 'SAVE10') setPromoError('Invalid code');
      else setState({ promo: 'SAVE10' });
    }, 600);
  }

  return (
    <Screen
      title="Cart"
      footer={<Button testID="checkout" title={`Checkout · ${money(total)}`} disabled={cart.length === 0} onPress={() => nav.navigate('Checkout')} />}
    >
      {cart.length === 0 ? <Body testID="cart-empty" muted>Your cart is empty</Body> : null}
      {cart.map((l, i) => (
        <ReanimatedSwipeable
          key={l.key}
          friction={1.5}
          rightThreshold={40}
          renderRightActions={() => (
            <Pressable
              testID={`remove-${i}`}
              accessibilityRole="button"
              onPress={() => setState((st) => ({ cart: st.cart.filter((x) => x.key !== l.key) }))}
              style={{ backgroundColor: c.danger, justifyContent: 'center', paddingHorizontal: 20, borderRadius: 14, marginBottom: 12 }}
            >
              <Text style={{ color: '#fff', fontWeight: '700' }}>Remove</Text>
            </Pressable>
          )}
        >
          <View testID={`cart-line-${i}`} style={[s.card, { backgroundColor: c.card }]}>
            <Text style={{ color: c.text, fontWeight: '700' }}>{product(l.productId).name}</Text>
            <Text style={{ color: c.muted }}>{`Size ${l.size} · ${l.color}${l.gift ? ' · Gift wrap' : ''}`}</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
              <Button testID={`line-minus-${i}`} kind="secondary" title="−" onPress={() => setQty(l.key, -1)} />
              <Text testID={`line-qty-${i}`} style={{ color: c.text, fontWeight: '700' }}>{`× ${l.qty}`}</Text>
              <Button testID={`line-plus-${i}`} kind="secondary" title="+" onPress={() => setQty(l.key, 1)} />
              <Text testID={`line-total-${i}`} style={{ color: c.text, marginLeft: 'auto' }}>{money(lineTotal(l))}</Text>
            </View>
          </View>
        </ReanimatedSwipeable>
      ))}
      <Gap />
      <View style={{ flexDirection: 'row', gap: 10, alignItems: 'flex-start' }}>
        <View style={{ flex: 1 }}>
          <Field testID="promo-input" placeholder="Promo code" autoCapitalize="characters" value={code} onChangeText={setCode} error={promoError} />
        </View>
        <Button testID="apply-promo" kind="secondary" title="Apply" disabled={applying || !code} onPress={apply} style={{ marginVertical: 0 }} />
      </View>
      {applying ? <Spinner label="Checking code" /> : null}
      {promo ? <Text testID="promo-applied" style={{ color: c.ok }}>{`${promo} applied: 10% off`}</Text> : null}
      <Gap />
      <Body testID="cart-subtotal">{`Subtotal ${money(subtotal)}`}</Body>
      {promo ? <Body testID="cart-discount">{`Discount −${money(discount)}`}</Body> : null}
      <Text testID="cart-total" style={{ color: c.text, fontSize: 20, fontWeight: '800' }}>{`Total ${money(total)}`}</Text>
    </Screen>
  );
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const POSTAL = /^([A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d|\d{5})$/;

export function Checkout() {
  const c = useColors();
  const nav = useNavigation<any>();
  const [form, setForm] = useState({ name: '', email: '', street: '', city: '', postal: '', phone: '' });
  const [touched, setTouched] = useState<Record<string, boolean>>({});
  const [shipping, setShipping] = useState<'standard' | 'express'>('standard');
  const [save, setSave] = useState(false);
  const [paying, setPaying] = useState(false);
  const emailError = touched.email && !EMAIL.test(form.email) ? 'Enter a valid email' : null;
  const postalError = touched.postal && !POSTAL.test(form.postal.trim()) ? 'Enter a valid postal code' : null;
  const valid = !!(form.name && EMAIL.test(form.email) && form.street && form.city && POSTAL.test(form.postal.trim()));
  const field = (k: keyof typeof form) => ({
    value: form[k],
    onChangeText: (t: string) => setForm((f) => ({ ...f, [k]: t })),
    onBlur: () => setTouched((t) => ({ ...t, [k]: true })),
  });

  function pay() {
    setPaying(true);
    setTimeout(() => {
      // The app works out the receipt on the JS thread: the screen is frozen meanwhile.
      const end = Date.now() + 500;
      while (Date.now() < end) {}
      const orders = getState().orders + 1;
      setState((st) => ({ orders, points: st.points + 120, cart: [], promo: null }));
      setPaying(false);
      nav.replace('OrderDone', { order: 10000 + orders, express: shipping === 'express' });
    }, 1500);
  }

  return (
    <View style={{ flex: 1 }}>
      <Screen title="Checkout" footer={<Button testID="place-order" title="Place order" disabled={!valid || paying} onPress={pay} />}>
        <Text style={[s.label, { color: c.muted }]}>Shipping address</Text>
        <Field testID="name-input" label="Full name" autoCapitalize="words" {...field('name')} />
        <Field testID="email-input" label="Email" keyboardType="email-address" autoCapitalize="none" autoCorrect={false} error={emailError} {...field('email')} />
        <Field testID="street-input" label="Street" {...field('street')} />
        <Field testID="city-input" label="City" {...field('city')} />
        <Field testID="postal-input" label="Postal code" autoCapitalize="characters" error={postalError} {...field('postal')} />
        <Field testID="checkout-phone" label="Phone (optional)" keyboardType="phone-pad" {...field('phone')} />
        <Text style={[s.label, { color: c.muted, marginTop: 8 }]}>Delivery</Text>
        <Radio testID="ship-standard" label="Standard · Free · 5–7 days" selected={shipping === 'standard'} onPress={() => setShipping('standard')} />
        <Radio testID="ship-express" label="Express · $9.99 · 1–2 days" selected={shipping === 'express'} onPress={() => setShipping('express')} />
        <Checkbox testID="save-address" label="Save this address" checked={save} onChange={setSave} />
      </Screen>
      {paying ? <Processing /> : null}
    </View>
  );
}

function Processing() {
  const c = useColors();
  const w = useSharedValue(0);
  useEffect(() => {
    w.value = withTiming(1, { duration: 1500 });
  }, [w]);
  const bar = useAnimatedStyle(() => ({ width: `${w.value * 100}%` }));
  return (
    <View style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'center', padding: 32 }}>
      <View style={[s.card, { backgroundColor: c.bg }]}>
        <Title>Processing payment</Title>
        <View style={{ height: 8, borderRadius: 4, backgroundColor: c.border, overflow: 'hidden' }}>
          <Animated.View style={[{ height: 8, backgroundColor: c.accent }, bar]} />
        </View>
      </View>
    </View>
  );
}

export function OrderDone() {
  const c = useColors();
  const nav = useNavigation<any>();
  const route = useRoute<any>();
  const insets = useSafeAreaInsets();
  const scale = useSharedValue(0.4);
  useEffect(() => {
    scale.value = withSpring(1, { damping: 8 });
  }, [scale]);
  const pop = useAnimatedStyle(() => ({ transform: [{ scale: scale.value }] }));
  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top + 40, padding: 24 }}>
      <Animated.View style={pop}>
        <Title testID="order-confirmed">Order confirmed</Title>
      </Animated.View>
      <Text testID="order-number" style={{ color: c.text, fontSize: 18 }}>{`Order #${route.params?.order}`}</Text>
      <Body muted>{route.params?.express ? 'Arrives in 1–2 days' : 'Arrives in 5–7 days'}</Body>
      <Gap h={24} />
      <Text style={{ color: c.muted }}>You earned</Text>
      <CountUp testID="points-earned" to={120} prefix="+" />
      <Gap h={24} />
      <Button
        testID="done"
        title="Done"
        onPress={() => {
          nav.navigate('Main', { screen: 'Shop' });
          orderClosed();
        }}
      />
      <Confetti />
    </View>
  );
}
