import { NativeModule, requireNativeModule } from 'expo';

import { PolarBleModuleEvents } from './PolarBle.types';

declare class PolarBleModule extends NativeModule<PolarBleModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<PolarBleModule>('PolarBle');
