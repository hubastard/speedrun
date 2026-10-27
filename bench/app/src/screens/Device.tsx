// Device: what the system says, live — location (setLocation, travel), permissions
// (setPermissions, launchApp's permissions), network (airplane mode), orientation, the
// system's dark mode, the photo library (addMedia), launch arguments, launches and returns
// to the foreground (stopApp, killApp, pressKey Home).
import { useFocusEffect } from '@react-navigation/native';
import * as ImagePicker from 'expo-image-picker';
import * as Location from 'expo-location';
import * as MediaLibrary from 'expo-media-library';
import { useNetworkState } from 'expo-network';
import * as Notifications from 'expo-notifications';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Text, useColorScheme, useWindowDimensions } from 'react-native';

import { launchArguments } from '../../modules/launch-arguments';
import { useStore } from '../store';
import { Button, Gap, s, Screen, useColors } from '../ui';

// Returns to the foreground since the app started (a module-level count: it lives as long as
// the process).
let resumed = 0;
let lastState = AppState.currentState;
AppState.addEventListener('change', (next) => {
  if (lastState.match(/inactive|background/) && next === 'active') resumed += 1;
  lastState = next;
});

const IGNORED_ARGS = /^(UI|NS|Apple|com\.apple|_|android|profile|expo)/;

export function Device() {
  const c = useColors();
  const scheme = useColorScheme();
  const { width, height } = useWindowDimensions();
  const network = useNetworkState();
  const launches = useStore((st) => st.launches);
  const [location, setLocation] = useState('Location: waiting');
  const [perms, setPerms] = useState<Record<string, string>>({});
  const [photos, setPhotos] = useState<number | null>(null);
  const [args] = useState(() => {
    try {
      return Object.entries(launchArguments())
        .filter(([k]) => !IGNORED_ARGS.test(k))
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([k, v]) => `${k}=${v}`)
        .join(', ');
    } catch {
      return 'unavailable';
    }
  });
  const [back, setBack] = useState(resumed);
  const watch = useRef<Location.LocationSubscription | null>(null);

  const refresh = useCallback(async () => {
    const [camera, loc, lib, notif] = await Promise.all([
      ImagePicker.getCameraPermissionsAsync(),
      Location.getForegroundPermissionsAsync(),
      MediaLibrary.getPermissionsAsync(),
      Notifications.getPermissionsAsync(),
    ]);
    setPerms({ Camera: camera.status, Location: loc.status, Photos: lib.status, Notifications: notif.status });
    if (lib.status === 'granted') {
      const page = await MediaLibrary.getAssetsAsync({ first: 1, mediaType: MediaLibrary.MediaType.photo });
      setPhotos(page.totalCount);
    } else setPhotos(null);
    if (loc.status === 'granted' && !watch.current) {
      watch.current = await Location.watchPositionAsync({ accuracy: Location.Accuracy.Highest, distanceInterval: 0, timeInterval: 500 }, (p) =>
        setLocation(`Location: ${p.coords.latitude.toFixed(4)}, ${p.coords.longitude.toFixed(4)}`),
      );
    }
    if (loc.status !== 'granted') setLocation('Location: no permission');
    setBack(resumed);
  }, []);

  useFocusEffect(
    useCallback(() => {
      refresh();
    }, [refresh]),
  );
  useEffect(() => {
    const sub = AppState.addEventListener('change', (st) => {
      if (st === 'active') refresh();
    });
    return () => {
      sub.remove();
      watch.current?.remove();
      watch.current = null;
    };
  }, [refresh]);

  return (
    <Screen title="Device">
      <Text testID="location" style={[s.body, { color: c.text }]}>{location}</Text>
      <Gap />
      {['Camera', 'Location', 'Photos', 'Notifications'].map((k) => (
        <Text key={k} testID={`perm-${k.toLowerCase()}`} style={[s.body, { color: c.text }]}>{`${k}: ${perms[k] ?? '…'}`}</Text>
      ))}
      <Gap />
      <Text testID="network" style={[s.body, { color: c.text }]}>{`Network: ${network.isConnected === false ? 'offline' : network.isConnected ? 'online' : '…'}`}</Text>
      <Text testID="orientation" style={[s.body, { color: c.text }]}>{`Orientation: ${width > height ? 'landscape' : 'portrait'}`}</Text>
      <Text testID="appearance-device" style={[s.body, { color: c.text }]}>{`Appearance: ${scheme === 'dark' ? 'dark' : 'light'}`}</Text>
      <Text testID="photo-count" style={[s.body, { color: c.text }]}>{photos === null ? 'Photos: no access' : `Photos: ${photos}`}</Text>
      {/* iOS 26 simulators report photos as not determined whatever the privacy database says
          (simctl's own grant included): the app asks, and the system's prompt answers. */}
      {perms.Photos === 'undetermined' ? (
        <Button
          testID="allow-photos"
          kind="secondary"
          title="Allow photos"
          onPress={async () => {
            await MediaLibrary.requestPermissionsAsync();
            refresh();
          }}
        />
      ) : null}
      <Text testID="launch-args" style={[s.body, { color: c.text }]}>{`Arguments: ${args || 'none'}`}</Text>
      <Text testID="launches" style={[s.body, { color: c.text }]}>{`Launches: ${launches}`}</Text>
      <Text testID="resumed" style={[s.body, { color: c.text }]}>{`Back in the foreground: ${back}`}</Text>
      <Gap />
      <Button testID="refresh-device" kind="secondary" title="Refresh" onPress={refresh} />
    </Screen>
  );
}
