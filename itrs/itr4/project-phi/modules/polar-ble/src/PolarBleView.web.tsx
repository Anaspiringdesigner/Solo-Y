import * as React from 'react';

import { PolarBleViewProps } from './PolarBle.types';

export default function PolarBleView(props: PolarBleViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
