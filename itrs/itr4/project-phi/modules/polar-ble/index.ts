import { requireNativeModule } from 'expo-modules-core';

// Grab the Kotlin module we just named "PolarBle"
const PolarBle = requireNativeModule('PolarBle');

// Export our ping function
export function ping(): string {
  return PolarBle.ping();
}