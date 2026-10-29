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

/**
 * The app's permission gate on the real platform. Android shows one permission dialog at a time
 * (a second request while one is open fails), so requests never overlap: they run one after the
 * other in the order asked (the controller asks Bluetooth at launch, so the session's request
 * waits for it), and asking again while the same request is pending reuses that pending promise.
 */
export function androidPermissionGate(
  platform: PlatformInfo = Platform,
  permissions: PermissionRequester = PermissionsAndroid,
): PermissionGate {
  let tail: Promise<unknown> = Promise.resolve();
  const pending: {board?: Promise<boolean>; session?: Promise<boolean>} = {};
  const ask = (kind: 'board' | 'session', request: () => Promise<boolean>): Promise<boolean> => {
    const open = pending[kind];
    if (open) {
      return open;
    }
    const run = tail.then(request, request);
    pending[kind] = run;
    tail = run.catch(() => undefined);
    const clear = () => {
      if (pending[kind] === run) {
        delete pending[kind];
      }
    };
    run.then(clear, clear);
    return run;
  };
  let boardAsked = false;
  const board = () => {
    boardAsked = true;
    return ask('board', () => requestBlePermissions(platform, permissions));
  };
  return {
    board,
    session: () => {
      if (!boardAsked) {
        board().catch(() => undefined); // Bluetooth first, even when the session asks first
      }
      return ask('session', () => requestSessionPermissions(platform, permissions));
    },
  };
}
