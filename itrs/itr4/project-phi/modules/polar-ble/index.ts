// Reexport the native module. On web, it will be resolved to PolarBleModule.web.ts
// and on native platforms to PolarBleModule.ts
export { default } from './src/PolarBleModule';
export { default as PolarBleView } from './src/PolarBleView';
export * from  './src/PolarBle.types';
