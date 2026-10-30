package expo.modules.composelab

import android.content.Context
import android.view.ViewGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.views.ExpoView
import kotlinx.coroutines.delay

class ComposeLabModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ComposeLab")
    View(ComposeLabView::class) {}
  }
}

// A Jetpack Compose screen inside the React Native app. Compose sends accessibility events only
// while an accessibility service is enabled, and a UiAutomation client (a test tool) is none:
// a read refreshes the root and the ~50 nodes fetched with it, and a tool's node cache serves
// the others as they were. Here 120 numbers come first, so what changes below them (a text, a
// progress bar that comes and goes, a line shown and hidden) is past those 50, in boxes of a
// fixed size: no view resizes, which would send an event.
class ComposeLabView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  override val shouldUseAndroidLayout = true

  // Added once attached: React Native measures a view before it is in a window, and a
  // ComposeView measured then finds no recomposer and throws.
  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    if (childCount > 0) return
    addView(
      ComposeView(context).apply {
        setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
        setContent { Lab() }
      },
      LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    )
  }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Lab() {
  var loads by remember { mutableIntStateOf(0) }
  var loading by remember { mutableStateOf(false) }
  var count by remember { mutableIntStateOf(0) }
  var details by remember { mutableStateOf(false) }
  LaunchedEffect(loads) {
    if (loads == 0) return@LaunchedEffect
    loading = true
    delay(2_000)
    loading = false
  }
  Column(Modifier.fillMaxSize().padding(16.dp).semantics { testTagsAsResourceId = true }) {
    Row {
      Button(onClick = { loads++ }, Modifier.testTag("compose-load")) { Text("Load") }
      Button(onClick = { count++ }, Modifier.testTag("compose-add")) { Text("Add") }
      Button(onClick = { details = !details }, Modifier.testTag("compose-toggle")) { Text("Details") }
    }
    repeat(12) { row ->
      Row { repeat(10) { Text("${row * 10 + it} ", fontSize = 12.sp) } }
    }
    Box(Modifier.width(240.dp).height(28.dp)) {
      Text("Loads finished: ${if (loading) loads - 1 else loads}", Modifier.testTag("compose-loads"))
    }
    Box(Modifier.width(240.dp).height(28.dp)) {
      Text("Count: $count", Modifier.testTag("compose-count"))
    }
    // Tagged holders are nodes of their own, their children listed under them: a cached
    // holder keeps the children it had.
    Box(Modifier.testTag("compose-bar-holder").fillMaxWidth().height(8.dp)) {
      if (loading) LinearProgressIndicator(Modifier.testTag("compose-bar"))
    }
    Box(Modifier.testTag("compose-details-holder").fillMaxWidth().height(28.dp)) {
      if (details) Text("Details shown", Modifier.testTag("compose-details"))
    }
  }
}
