import { requireNativeView } from 'expo';
import * as React from 'react';

import { PolarBleViewProps } from './PolarBle.types';

const NativeView: React.ComponentType<PolarBleViewProps> =
  requireNativeView('PolarBle');

export default function PolarBleView(props: PolarBleViewProps) {
  return <NativeView {...props} />;
}
