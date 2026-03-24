import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, PermissionsAndroid, Platform } from 'react-native';
import { BleManager } from 'react-native-ble-plx';
import { Buffer } from 'buffer';

const bleManager = new BleManager();

// Standard BLE UUIDs for Heart Rate
const HR_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb';
const HR_CHAR_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

export default function App() {
  const [connectionStatus, setConnectionStatus] = useState('Disconnected');
  const [heartRate, setHeartRate] = useState(0);
  const [latestRR, setLatestRR] = useState(0);

  useEffect(() => {
    requestPermissions();
    return () => bleManager.destroy();
  }, []);

  const requestPermissions = async () => {
    if (Platform.OS === 'android') {
      await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
        PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION,
      ]);
    }
  };

  const scanAndConnect = () => {
    setConnectionStatus('Scanning for Polar H10...');
    
    bleManager.startDeviceScan(null, null, (error, device) => {
      if (error) {
        console.error("Scan Error:", error);
        setConnectionStatus('Scan Error');
        return;
      }

      if (device && device.name && device.name.includes('Polar H10')) {
        bleManager.stopDeviceScan();
        setConnectionStatus('Connecting...');
        connectToDevice(device);
      }
    });
  };

  const connectToDevice = async (device: any) => {
    try {
      const connectedDevice = await device.connect();
      setConnectionStatus(`Connected to ${device.name}`);
      await connectedDevice.discoverAllServicesAndCharacteristics();
      
      connectedDevice.monitorCharacteristicForService(
        HR_SERVICE_UUID,
        HR_CHAR_UUID,
        (error, characteristic) => {
          if (error) {
            console.error("Stream Error:", error);
            return;
          }
          if (characteristic?.value) {
            parseHeartRateData(characteristic.value);
          }
        }
      );
    } catch (error) {
      console.error("Connection Failed:", error);
      setConnectionStatus('Connection Failed');
    }
  };

  // Decode the Base64 bytes into BPM and HRV (RR intervals)
  const parseHeartRateData = (base64String: string) => {
    const buffer = Buffer.from(base64String, 'base64');
    
    // First byte contains flags
    const flags = buffer.readUInt8(0);
    
    // Bit 0 checks if HR is 8-bit or 16-bit
    const is16BitHR = (flags & 0x01) !== 0;
    
    // Read Heart Rate
    const hrValue = is16BitHR ? buffer.readUInt16LE(1) : buffer.readUInt8(1);
    setHeartRate(hrValue);

    // Bit 4 checks if RR intervals (HRV) are present
    const rrIntervalPresent = (flags & 0x10) !== 0;
    
    if (rrIntervalPresent) {
      let offset = is16BitHR ? 3 : 2;
      
      // There can be multiple RR intervals in one packet
      while (offset < buffer.length) {
        const rrValue = buffer.readUInt16LE(offset);
        // Polar measures RR in 1/1024 of a second. Convert to milliseconds.
        const rrInMs = Math.round((rrValue / 1024.0) * 1000.0); 
        setLatestRR(rrInMs);
        offset += 2;
        
        // Console log for debugging the raw stream
        console.log(`BPM: ${hrValue} | RR: ${rrInMs}ms`);
      }
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.header}>🧠 Bio-Brain V2</Text>
      
      <View style={styles.statusBox}>
        <Text style={styles.label}>Status: {connectionStatus}</Text>
        <Text style={styles.dataText}>BPM: {heartRate}</Text>
        <Text style={styles.dataText}>Latest RR (HRV): {latestRR} ms</Text>
      </View>

      <TouchableOpacity style={styles.button} onPress={scanAndConnect}>
        <Text style={styles.buttonText}>Pair Polar H10</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f4f4f8', alignItems: 'center', justifyContent: 'center', padding: 20 },
  header: { fontSize: 28, fontWeight: 'bold', marginBottom: 30, color: '#333' },
  statusBox: { backgroundColor: '#fff', padding: 30, borderRadius: 15, width: '100%', alignItems: 'center', shadowColor: '#000', shadowOpacity: 0.1, shadowRadius: 10, marginBottom: 30 },
  label: { fontSize: 16, color: '#666', marginBottom: 15, fontWeight: 'bold' },
  dataText: { fontSize: 32, fontWeight: 'bold', color: '#e74c3c', marginVertical: 5 },
  button: { backgroundColor: '#3498db', paddingVertical: 15, paddingHorizontal: 40, borderRadius: 25 },
  buttonText: { color: '#fff', fontSize: 18, fontWeight: 'bold' },
});