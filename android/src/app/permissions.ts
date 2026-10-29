// Android runtime permissions of a conversation (ARCHITECTURE.md §7), asked when first needed:
// Bluetooth at launch (src/board/BleAdapter.ts `requestBlePermissions`), the microphone and, on
// Android 13+ (API 33), notifications before a session starts. Refusing notifications only hides
// the foreground service's notification; refusing the microphone stops the start (the controller
// shows `permission.microphone`). Everything is injectable for tests.
import {PermissionsAndroid, Platform} from 'react-native';
import {requestBlePermissions, type PermissionRequester} from '../board/BleAdapter';
import type {PermissionGate} from '../engine/ConversationController';

type Permission = Parameters<typeof PermissionsAndroid.request>[0];

export interface PlatformInfo {
  readonly OS: string;
  readonly Version: number | string;
}

/** The permissions a session asks for on Android `apiLevel`. */
export function sessionPermissionsFor(apiLevel: number): Permission[] {
  return apiLevel >= 33
    ? ['android.permission.RECORD_AUDIO', 'android.permission.POST_NOTIFICATIONS']
    : ['android.permission.RECORD_AUDIO'];
}

/** Asks for the session's permissions; true when the microphone is granted. */
export async function requestSessionPermissions(
  platform: PlatformInfo = Platform,
  permissions: PermissionRequester = PermissionsAndroid,
): Promise<boolean> {
  if (platform.OS !== 'android') {
    return true;
  }
  const wanted = sessionPermissionsFor(Number(platform.Version));
  const results = await permissions.requestMultiple(wanted);
  return results['android.permission.RECORD_AUDIO'] === 'granted';
}

/** The app's permission gate on the real platform. */
export function androidPermissionGate(
  platform: PlatformInfo = Platform,
  permissions: PermissionRequester = PermissionsAndroid,
): PermissionGate {
  return {
    session: () => requestSessionPermissions(platform, permissions),
    board: () => requestBlePermissions(platform, permissions),
  };
}
