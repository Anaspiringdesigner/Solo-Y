#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "MAX30105.h"

MAX30105 particleSensor;

static const int SDA_PIN = 21;
static const int SCL_PIN = 22;
static const uint32_t SAMPLE_INTERVAL_MS = 20; // ~50 Hz

// BLE UUIDs
static BLEUUID SERVICE_UUID("12345678-1234-1234-1234-1234567890ab");
static BLEUUID SAMPLE_CHAR_UUID("12345678-1234-1234-1234-1234567890ac");
static BLEUUID STATUS_CHAR_UUID("12345678-1234-1234-1234-1234567890ad");

BLECharacteristic* sampleChar = nullptr;
BLECharacteristic* statusChar = nullptr;
volatile bool deviceConnected = false;

unsigned long lastSampleMs = 0;
uint32_t seqNo = 0;

// Saturation / signal health tracking
uint32_t satCount = 0;
uint32_t sampleCount = 0;
unsigned long lastHealthMs = 0;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("[BLE] connected");
  }

  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    BLEDevice::startAdvertising();
    Serial.println("[BLE] disconnected, advertising restarted");
  }
};

#pragma pack(push, 1)
struct SamplePacket {
  uint32_t seq;
  uint32_t ts_ms;
  int32_t ir;
  int32_t red;
};
#pragma pack(pop)

void updateStatus(const char* text) {
  if (statusChar) {
    statusChar->setValue((uint8_t*)text, strlen(text));
    statusChar->notify();
  }
  Serial.println(text);
}

bool initSensor() {
  Wire.begin(SDA_PIN, SCL_PIN);

  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    return false;
  }

  // MAX30102 setup tuning for wearable finger contact, avoid clipping
  byte ledBrightness = 0x24; // LOWER than 0x7F
  byte sampleAverage = 4;
  byte ledMode = 2;      // Red + IR
  int sampleRate = 100;  // sensor internal rate
  int pulseWidth = 215;  // narrower pulse to reduce saturation
  int adcRange = 4096;

  particleSensor.setup(
    ledBrightness,
    sampleAverage,
    ledMode,
    sampleRate,
    pulseWidth,
    adcRange
  );

  // Keep amplitudes moderate; reduce if still saturating
  particleSensor.setPulseAmplitudeRed(0x24);
  particleSensor.setPulseAmplitudeIR(0x24);
  particleSensor.setPulseAmplitudeGreen(0x00);

  // Optional slight settle delay
  delay(200);
  return true;
}

void initBle() {
  BLEDevice::init("ESP32-MAX30102");

  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);

  sampleChar = service->createCharacteristic(
    SAMPLE_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  sampleChar->addDescriptor(new BLE2902());

  statusChar = service->createCharacteristic(
    STATUS_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  statusChar->addDescriptor(new BLE2902());
  statusChar->setValue("booting");

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  initBle();

  if (!initSensor()) {
    updateStatus("sensor_init_failed");
    while (true) {
      delay(1000);
    }
  }

  updateStatus("ready");
  Serial.println("[SENSOR] initialized");
}

void loop() {
  const unsigned long now = millis();

  if (now - lastSampleMs >= SAMPLE_INTERVAL_MS) {
    lastSampleMs = now;

    int32_t ir = particleSensor.getIR();
    int32_t red = particleSensor.getRed();

    SamplePacket pkt;
    pkt.seq = ++seqNo;
    pkt.ts_ms = now;
    pkt.ir = ir;
    pkt.red = red;

    // Health stats
    sampleCount++;
    if (ir >= 260000 || red >= 260000) {
      satCount++;
    }

    // Print every sample (can reduce if too chatty)
    Serial.print(pkt.seq);
    Serial.print(',');
    Serial.print(pkt.ts_ms);
    Serial.print(',');
    Serial.print(pkt.ir);
    Serial.print(',');
    Serial.println(pkt.red);

    // BLE notify
    if (deviceConnected && sampleChar) {
      sampleChar->setValue((uint8_t*)&pkt, sizeof(pkt));
      sampleChar->notify();
    }
  }

  // Report health every 5s
  if (now - lastHealthMs >= 5000) {
    lastHealthMs = now;
    float satPct = (sampleCount > 0) ? (100.0f * satCount / sampleCount) : 0.0f;

    Serial.print("[HEALTH] sat_pct=");
    Serial.print(satPct, 1);
    Serial.print("% samples=");
    Serial.println(sampleCount);

    if (satPct > 20.0f) {
      updateStatus("signal_saturated");
    } else {
      updateStatus("signal_ok");
    }

    satCount = 0;
    sampleCount = 0;
  }
}