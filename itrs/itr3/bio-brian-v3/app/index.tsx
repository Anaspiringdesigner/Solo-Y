import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, PermissionsAndroid, Platform, ScrollView } from 'react-native';
import { BleManager } from 'react-native-ble-plx';
import { Buffer } from 'buffer';

const bleManager = new BleManager();

// Standard Live Heart Rate Service
const HR_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb';
const HR_CHAR_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

// --- POLAR MEASUREMENT DATA (PMD) SERVICES ---
// This is the hidden gateway to the H10's internal memory
const PMD_SERVICE_UUID = 'fb005c80-02e7-f387-1cad-8acd2d8df0c8';
const PMD_CONTROL_POINT_UUID = 'fb005c81-02e7-f387-1cad-8acd2d8df0c8';

export default function App() {
  const [connectionStatus, setConnectionStatus] = useState('Disconnected');
  const [connectedDevice, setConnectedDevice] = useState<any>(null);
  const [heartRate, setHeartRate] = useState(0);

  useEffect(() => {
    requestPermissions();
  }, []);

  const requestPermissions = async () => {
    if (Platform.OS === 'android') {
      await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
      ]);
    }
  };

  const scanAndConnect = () => {
    setConnectionStatus('Scanning for Polar H10...');
    
    bleManager.startDeviceScan(null, null, (error, device) => {
      if (error) {
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
      const peripheral = await device.connect();
      setConnectedDevice(peripheral);
      setConnectionStatus(`Connected to ${device.name}`);
      await peripheral.discoverAllServicesAndCharacteristics();
      
      // Start listening to the live heartbeat just so we know it's alive
      peripheral.monitorCharacteristicForService(
        HR_SERVICE_UUID,
        HR_CHAR_UUID,
        (error: any, characteristic: any) => {
          if (error) return;
          if (characteristic?.value) {
            const buffer = Buffer.from(characteristic.value, 'base64');
            const flags = buffer.readUInt8(0);
            const is16BitHR = (flags & 0x01) !== 0;
            setHeartRate(is16BitHR ? buffer.readUInt16LE(1) : buffer.readUInt8(1));
          }
        }
      );
    } catch (error) {
      setConnectionStatus('Connection Failed.');
    }
  };

  // --- THE OFFLINE COMMAND ---
  const triggerOfflineRecording = async () => {
    if (!connectedDevice) {
      alert("Please connect to the Polar H10 first!");
      return;
    }

    try {
      // 1. In Bluetooth architecture, we write raw bytes to the Control Point
      // 0x0A is typically the op-code to initiate an internal file system command
      const command = Buffer.from([0x0A, 0x01]).toString('base64'); 

      await connectedDevice.writeCharacteristicWithResponseForService(
        PMD_SERVICE_UUID,
        PMD_CONTROL_POINT_UUID,
        command
      );

      alert("Success! The H10 is now recording to its internal chip.");
    } catch (error) {
      console.error("Failed to trigger offline mode:", error);
      alert("Failed to send the offline command. Check console.");
    }
  };

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.header}>🧠 Bio-Brain (Hardware Mode)</Text>
      
      <View style={styles.statusBox}>
        <Text style={styles.label}>Status: {connectionStatus}</Text>
        <Text style={styles.dataText}>Live BPM: {heartRate}</Text>
      </View>

      <TouchableOpacity style={styles.button} onPress={scanAndConnect}>
        <Text style={styles.buttonText}>Pair Polar H10</Text>
      </TouchableOpacity>

      {/* --- OFFLINE HARDWARE UI --- */}
      <View style={styles.hardwareSection}>
        <Text style={styles.subHeader}>⚙️ Internal Memory Vault</Text>
        <Text style={styles.explainerText}>
          Send a cryptographic hex command directly to the H10's PMD Control Point. 
          Once started, you can turn your phone completely off.
        </Text>
        
        <TouchableOpacity style={styles.hardwareButton} onPress={triggerOfflineRecording}>
          <Text style={styles.buttonText}>Start Offline Recording</Text>
        </TouchableOpacity>
      </View>

    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flexGrow: 1, backgroundColor: '#1a1a1a', alignItems: 'center', padding: 20, paddingBottom: 50 },
  header: { fontSize: 26, fontWeight: 'bold', marginBottom: 20, color: '#fff', marginTop: 40 },
  statusBox: { backgroundColor: '#333', padding: 20, borderRadius: 15, width: '100%', alignItems: 'center', marginBottom: 20 },
  label: { fontSize: 16, color: '#aaa', marginBottom: 10, fontWeight: 'bold' },
  dataText: { fontSize: 32, fontWeight: 'bold', color: '#e74c3c', marginVertical: 5 },
  button: { backgroundColor: '#2980b9', paddingVertical: 15, paddingHorizontal: 40, borderRadius: 25, marginBottom: 30 },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: 'bold' },
  
  hardwareSection: { width: '100%', alignItems: 'center', backgroundColor: '#2c3e50', padding: 20, borderRadius: 15 },
  subHeader: { fontSize: 18, fontWeight: 'bold', color: '#fff', marginBottom: 10 },
  explainerText: { color: '#bdc3c7', textAlign: 'center', marginBottom: 20, fontSize: 14, lineHeight: 20 },
  hardwareButton: { backgroundColor: '#8e44ad', paddingVertical: 15, paddingHorizontal: 30, borderRadius: 10, width: '100%', alignItems: 'center' },
});