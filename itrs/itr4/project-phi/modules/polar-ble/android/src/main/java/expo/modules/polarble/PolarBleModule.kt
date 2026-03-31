package expo.modules.polarble

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApiDefaultImpl

class PolarBleModule : Module() {
  // Declare the Polar API instance
  private lateinit var api: PolarBleApi

  override fun definition() = ModuleDefinition {
    Name("PolarBle")

    // This runs silently when the app boots up
    OnCreate {
      val context = appContext.reactContext ?: return@OnCreate
      
      // Boot up the official Polar SDK
      api = PolarBleApiDefaultImpl.defaultImplementation(
        context,
        PolarBleApi.ALL_FEATURES
      )
    }

    // A simple test function exposed to JavaScript
    Function("ping") {
      return@Function "Polar SDK Initialized!"
    }
  }
}