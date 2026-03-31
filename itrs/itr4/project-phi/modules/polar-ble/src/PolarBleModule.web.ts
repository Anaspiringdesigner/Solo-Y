import { registerWebModule, NativeModule } from 'expo';

import { ChangeEventPayload } from './PolarBle.types';

type PolarBleModuleEvents = {
  onChange: (params: ChangeEventPayload) => void;
}

class PolarBleModule extends NativeModule<PolarBleModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
};

export default registerWebModule(PolarBleModule, 'PolarBleModule');
