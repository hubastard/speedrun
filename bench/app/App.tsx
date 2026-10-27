// Speedrun Bench: an app made to be tested. Signed out: onboarding (first launch only) and
// sign in. Signed in (or as a guest): five tabs (Home, Shop, Chats, Lab, Profile) and the
// screens they open. Deep links: speedrunbench://product/7, speedrunbench://lab/gestures, …
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { DarkTheme, DefaultTheme, LinkingOptions, NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { StatusBar } from 'expo-status-bar';
import React from 'react';
import { Text, useColorScheme } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { PopupHost, ToastHost } from './src/popups';
import { Code, Onboarding, SignIn } from './src/screens/Auth';
import { Chat, Chats } from './src/screens/Chats';
import { Device } from './src/screens/Device';
import { Feed } from './src/screens/Feed';
import { Drag, Gestures, LongList } from './src/screens/Gestures';
import { Inputs } from './src/screens/Inputs';
import { Animations, Lab, Scene } from './src/screens/Lab';
import { EditProfile, Pin, Profile, Settings } from './src/screens/Profile';
import { Selectors } from './src/screens/Selectors';
import { Cart, Checkout, OrderDone, ProductScreen, Shop } from './src/screens/Shop';
import { getState, useStore } from './src/store';

const Stack = createNativeStackNavigator();
const Tab = createBottomTabNavigator();

const TABS: { name: string; glyph: string; component: React.ComponentType<any> }[] = [
  { name: 'Home', glyph: '⌂', component: Feed },
  { name: 'Shop', glyph: '◫', component: Shop },
  { name: 'Chats', glyph: '✉', component: Chats },
  { name: 'Lab', glyph: '⚗', component: Lab },
  { name: 'Profile', glyph: '☺', component: Profile },
];

function Main() {
  return (
    <Tab.Navigator screenOptions={{ headerShown: false }}>
      {TABS.map((t) => (
        <Tab.Screen
          key={t.name}
          name={t.name}
          component={t.component}
          options={{
            tabBarButtonTestID: `tab-${t.name.toLowerCase()}`,
            tabBarAccessibilityLabel: t.name,
            tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 20 }}>{t.glyph}</Text>,
          }}
        />
      ))}
    </Tab.Navigator>
  );
}

const linking: LinkingOptions<any> = {
  prefixes: ['speedrunbench://'],
  config: {
    screens: {
      Main: { screens: { Home: 'home', Shop: 'shop', Chats: 'chats', Lab: 'lab', Profile: 'profile' } },
      Product: 'product/:id',
      Cart: 'cart',
      Chat: 'chat/:id',
      Scene: 'lab/animation/:scene',
      Gestures: 'lab/gestures',
      Drag: 'lab/drag',
      Selectors: 'lab/selectors',
      Inputs: 'lab/inputs',
      Device: 'lab/device',
      LongList: 'lab/list',
    },
  },
};

// Onboarding shows on the first launch after an install or clearState, until it is left.
const firstLaunch = getState().launches === 1;

export default function App() {
  const scheme = useColorScheme();
  const session = useStore((st) => st.session);
  const onboarded = useStore((st) => st.onboarded);
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <NavigationContainer theme={scheme === 'dark' ? DarkTheme : DefaultTheme} linking={linking}>
          <Stack.Navigator screenOptions={{ headerShown: false }}>
            {session === 'none' ? (
              <>
                {/* The first screen opens: onboarding on a first launch, until it is left. */}
                {firstLaunch && !onboarded ? <Stack.Screen name="Onboarding" component={Onboarding} /> : null}
                <Stack.Screen name="SignIn" component={SignIn} />
                <Stack.Screen name="Code" component={Code} />
              </>
            ) : (
              <>
                <Stack.Screen name="Main" component={Main} />
                <Stack.Screen name="Product" component={ProductScreen} />
                <Stack.Screen name="Cart" component={Cart} />
                <Stack.Screen name="Checkout" component={Checkout} />
                <Stack.Screen name="OrderDone" component={OrderDone} options={{ gestureEnabled: false, animation: 'fade' }} />
                <Stack.Screen name="Chat" component={Chat} />
                <Stack.Screen name="EditProfile" component={EditProfile} />
                <Stack.Screen name="Settings" component={Settings} />
                <Stack.Screen name="Pin" component={Pin} />
                <Stack.Screen name="Animations" component={Animations} />
                <Stack.Screen name="Scene" component={Scene} />
                <Stack.Screen name="Gestures" component={Gestures} />
                <Stack.Screen name="Drag" component={Drag} />
                <Stack.Screen name="LongList" component={LongList} />
                <Stack.Screen name="Selectors" component={Selectors} />
                <Stack.Screen name="Inputs" component={Inputs} />
                <Stack.Screen name="Device" component={Device} options={{ animation: 'slide_from_bottom' }} />
              </>
            )}
          </Stack.Navigator>
        </NavigationContainer>
        <ToastHost />
        <PopupHost />
        <StatusBar style="auto" />
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
