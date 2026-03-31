import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, PermissionsAndroid, Platform, ScrollView } from 'react-native';
import { BleManager } from 'react-native-ble-plx';
import { Buffer } from 'buffer';

const bleManager = new BleManager();

const HR_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb';
const HR_CHAR_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

// --- POLAR MEASUREMENT DATA (PMD) ---
const PMD_SERVICE_UUID = 'fb005c80-02e7-f387-1cad-8acd2d8df0c8';
const PMD_CONTROL_POINT_UUID = 'fb005c81-02e7-f387-1cad-8acd2d8df0c8';
// THE DATA PIPE: This is where the file chunks will be streamed
const PMD_DATA_UUID = 'fb005c82-02e7-f387-1cad-8acd2d8df0c8';

export default function App() {
  const [connectionStatus, setConnectionStatus] = useState('Disconnected');
  const [connectedDevice, setConnectedDevice] = useState<any>(null);
  const [heartRate, setHeartRate] = useState(0);
  const [downloadStatus, setDownloadStatus] = useState('Waiting...');

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
      if (error) return;
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

  const triggerOfflineRecording = async () => {
    if (!connectedDevice) return alert("Connect first!");
    try {
      const command = Buffer.from([0x0A, 0x01]).toString('base64'); 
      await connectedDevice.writeCharacteristicWithResponseForService(PMD_SERVICE_UUID, PMD_CONTROL_POINT_UUID, command);
      alert("Recording Started!");
    } catch (error) {
      alert("Failed to start recording.");
    }
  };

  // --- NEW: STOP & PREP FOR DOWNLOAD ---
  const stopRecordingAndListen = async () => {
    if (!connectedDevice) return alert("Connect first!");
    try {
      setDownloadStatus('Stopping recording & opening data pipe...');

      // 1. Open the Data Pipe so we can listen for the file chunks
      connectedDevice.monitorCharacteristicForService(
        PMD_SERVICE_UUID,
        PMD_DATA_UUID,
        (error: any, characteristic: any) => {
          if (error) {
            console.error("Data Pipe Error:", error);
            return;
          }
          if (characteristic?.value) {
            // This is the raw binary matrix code hitting your app!
            console.log("RAW PACKET RECEIVED:", characteristic.value);
            setDownloadStatus('Receiving binary chunks... Check console!');
          }
        }
      );

      // 2. Send the Stop Command (0x0A, 0x00) to the Control Point
      const stopCommand = Buffer.from([0x0A, 0x00]).toString('base64'); 
      await connectedDevice.writeCharacteristicWithResponseForService(
        PMD_SERVICE_UUID, 
        PMD_CONTROL_POINT_UUID, 
        stopCommand
      );

      alert("Recording Stopped. The strap is preparing the file.");
    } catch (error) {
      console.error(error);
      alert("Failed to stop recording.");
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

      <View style={styles.hardwareSection}>
        <Text style={styles.subHeader}>⚙️ Internal Memory Vault</Text>
        
        <TouchableOpacity style={styles.hardwareButton} onPress={triggerOfflineRecording}>
          <Text style={styles.buttonText}>1. Start Offline Recording</Text>
        </TouchableOpacity>

        <TouchableOpacity style={[styles.hardwareButton, { backgroundColor: '#e74c3c', marginTop: 15 }]} onPress={stopRecordingAndListen}>
          <Text style={styles.buttonText}>2. Stop & Open Data Pipe</Text>
        </TouchableOpacity>

        <Text style={styles.terminalText}>Download Status: {downloadStatus}</Text>
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
  subHeader: { fontSize: 18, fontWeight: 'bold', color: '#fff', marginBottom: 20 },
  hardwareButton: { backgroundColor: '#8e44ad', paddingVertical: 15, paddingHorizontal: 30, borderRadius: 10, width: '100%', alignItems: 'center' },
  terminalText: { color: '#2ecc71', marginTop: 20, fontSize: 14, fontFamily: 'monospace', textAlign: 'center' },
});