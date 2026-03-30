package com.ultraelectronica.flick

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat as MediaNotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MusicNotificationService : Service() {

    companion object {
        const val CHANNEL_ID = "flick_music_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_PLAY_PAUSE = "com.ultraelectronica.flick.PLAY_PAUSE"
        const val ACTION_NEXT = "com.ultraelectronica.flick.NEXT"
        const val ACTION_PREVIOUS = "com.ultraelectronica.flick.PREVIOUS"
        const val ACTION_STOP = "com.ultraelectronica.flick.STOP"
        const val ACTION_SHUFFLE = "com.ultraelectronica.flick.SHUFFLE"
        const val ACTION_FAVORITE = "com.ultraelectronica.flick.FAVORITE"

        private const val PLAYER_CHANNEL = "com.ultraelectronica.flick/player"
    }

    private lateinit var mediaSession: MediaSessionCompat
    private lateinit var notificationManager: NotificationManager
    private var methodChannel: MethodChannel? = null
    private var isForegroundServiceStarted = false

    private var currentTitle: String = "Unknown"
    private var currentArtist: String = "Unknown Artist"
    private var currentAlbumArtPath: String? = null
    private var isPlaying: Boolean = false
    private var currentDuration: Long = 0
    private var currentPosition: Long = 0
    private var isShuffleMode: Boolean = false
    private var isFavorite: Boolean = false

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            android.util.Log.d("MusicNotification", "Received action: ${intent?.action}")
            when (intent?.action) {
                ACTION_PLAY_PAUSE -> {
                    android.util.Log.d("MusicNotification", "Play/Pause tapped. Current isPlaying=$isPlaying")
                    sendCommandToFlutter("togglePlayPause")
                    // Optimistic local update — flip immediately without waiting for Flutter
                    isPlaying = !isPlaying
                    val notification = buildNotification()
                    notificationManager.notify(NOTIFICATION_ID, notification)
                    android.util.Log.d("MusicNotification", "Optimistically updated to isPlaying=$isPlaying")
                }
                ACTION_NEXT -> {
                    android.util.Log.d("MusicNotification", "Next action triggered")
                    sendCommandToFlutter("next")
                }
                ACTION_PREVIOUS -> {
                    android.util.Log.d("MusicNotification", "Previous action triggered")
                    sendCommandToFlutter("previous")
                }
                ACTION_STOP -> {
                    android.util.Log.d("MusicNotification", "Stop action triggered")
                    sendCommandToFlutter("stop")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                ACTION_SHUFFLE -> {
                    android.util.Log.d("MusicNotification", "Shuffle action triggered")
                    isShuffleMode = !isShuffleMode
                    sendCommandToFlutter("toggleShuffle")
                    val notification = buildNotification()
                    notificationManager.notify(NOTIFICATION_ID, notification)
                }
                ACTION_FAVORITE -> {
                    android.util.Log.d("MusicNotification", "Favorite action triggered")
                    isFavorite = !isFavorite
                    sendCommandToFlutter("toggleFavorite")
                    val notification = buildNotification()
                    notificationManager.notify(NOTIFICATION_ID, notification)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
        setupMediaSession()

        val filter = IntentFilter().apply {
            addAction(ACTION_PLAY_PAUSE)
            addAction(ACTION_NEXT)
            addAction(ACTION_PREVIOUS)
            addAction(ACTION_STOP)
            addAction(ACTION_SHUFFLE)
            addAction(ACTION_FAVORITE)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(actionReceiver, filter)
        }

        FlutterEngineCache.getInstance().get("main_engine")?.let { engine ->
            methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let {
            if (it.hasExtra("title")) currentTitle = it.getStringExtra("title") ?: "Unknown"
            if (it.hasExtra("artist")) currentArtist = it.getStringExtra("artist") ?: "Unknown Artist"
            if (it.hasExtra("albumArtPath")) currentAlbumArtPath = it.getStringExtra("albumArtPath")
            if (it.hasExtra("isPlaying")) isPlaying = it.getBooleanExtra("isPlaying", false)
            if (it.hasExtra("duration")) {
                // Fix for deprecated Bundle.get() — use typed getters with fallback
                currentDuration = it.getLongExtra("duration", -1L).takeIf { v -> v != -1L }
                    ?: it.getIntExtra("duration", 0).toLong()
            }
            if (it.hasExtra("position")) {
                currentPosition = it.getLongExtra("position", -1L).takeIf { v -> v != -1L }
                    ?: it.getIntExtra("position", 0).toLong()
            }
            if (it.hasExtra("isShuffle")) isShuffleMode = it.getBooleanExtra("isShuffle", false)
            if (it.hasExtra("isFavorite")) isFavorite = it.getBooleanExtra("isFavorite", false)
        }

        val notification = buildNotification()

        if (!isForegroundServiceStarted) {
            android.util.Log.d("MusicNotification", "Starting foreground service: isPlaying=$isPlaying")
            startForeground(NOTIFICATION_ID, notification)
            isForegroundServiceStarted = true
        } else {
            android.util.Log.d("MusicNotification", "Updating notification: isPlaying=$isPlaying, position=$currentPosition, duration=$currentDuration")
            notificationManager.notify(NOTIFICATION_ID, notification)
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Keep service running when task is removed
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(actionReceiver)
        } catch (e: Exception) {
            // Receiver was not registered
        }
        mediaSession.release()
        isForegroundServiceStarted = false
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Music Playback",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows currently playing song with playback controls"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun setupMediaSession() {
        mediaSession = MediaSessionCompat(this, "FlickMusicSession").apply {
            // FLAG_HANDLES_MEDIA_BUTTONS and FLAG_HANDLES_TRANSPORT_CONTROLS are deprecated
            // in API 31+. Setting them is a no-op on modern Android — the MediaSession
            // automatically handles these via the registered callback below.
            @Suppress("DEPRECATION")
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )

            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() { sendCommandToFlutter("play") }
                override fun onPause() { sendCommandToFlutter("pause") }
                override fun onSkipToNext() { sendCommandToFlutter("next") }
                override fun onSkipToPrevious() { sendCommandToFlutter("previous") }
                override fun onStop() {
                    sendCommandToFlutter("stop")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                override fun onSeekTo(pos: Long) {
                    sendCommandToFlutter("seek", mapOf("position" to pos))
                }
                override fun onSetShuffleMode(shuffleMode: Int) {
                    sendCommandToFlutter("toggleShuffle")
                }
                override fun onCustomAction(action: String?, extras: android.os.Bundle?) {
                    android.util.Log.d("MusicNotification", "Custom action received: $action")
                    when (action) {
                        ACTION_SHUFFLE -> {
                            isShuffleMode = !isShuffleMode
                            sendCommandToFlutter("toggleShuffle")
                            updatePlaybackState()
                            val notification = buildNotification()
                            notificationManager.notify(NOTIFICATION_ID, notification)
                        }
                        ACTION_FAVORITE -> {
                            isFavorite = !isFavorite
                            sendCommandToFlutter("toggleFavorite")
                            updatePlaybackState()
                            val notification = buildNotification()
                            notificationManager.notify(NOTIFICATION_ID, notification)
                        }
                    }
                }
            })

            isActive = true
        }

        updateMediaSessionMetadata()
        updatePlaybackState()
    }

    private fun updateMediaSessionMetadata() {
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDuration)

        currentAlbumArtPath?.let { path ->
            try {
                val bitmap = BitmapFactory.decodeFile(path)
                if (bitmap != null) {
                    metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
                }
                else {}
            } catch (e: Exception) {
                android.util.Log.w("MusicNotification", "Failed to load album art: ${e.message}")
            }
        }

        mediaSession.setMetadata(metadata.build())
    }

    private fun updatePlaybackState() {
        val state = if (isPlaying) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED
        val playbackSpeed = if (isPlaying) 1.0f else 0.0f

        mediaSession.setShuffleMode(
            if (isShuffleMode) PlaybackStateCompat.SHUFFLE_MODE_ALL
            else PlaybackStateCompat.SHUFFLE_MODE_NONE
        )

        val stateBuilder = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                PlaybackStateCompat.ACTION_PAUSE or
                PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                PlaybackStateCompat.ACTION_STOP or
                PlaybackStateCompat.ACTION_SEEK_TO or
                PlaybackStateCompat.ACTION_SET_SHUFFLE_MODE
            )
            .setState(state, currentPosition, playbackSpeed, android.os.SystemClock.elapsedRealtime())

        // Android 13+ requires custom actions in PlaybackState for them to appear
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val shuffleIcon = if (isShuffleMode) R.drawable.ic_shuffle_on else R.drawable.ic_shuffle
            val shuffleTitle = if (isShuffleMode) "Shuffle On" else "Shuffle Off"
            
            stateBuilder.addCustomAction(
                PlaybackStateCompat.CustomAction.Builder(
                    ACTION_SHUFFLE,
                    shuffleTitle,
                    shuffleIcon
                ).build()
            )

            val favoriteIcon = if (isFavorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border
            val favoriteTitle = if (isFavorite) "Unfavorite" else "Favorite"
            
            stateBuilder.addCustomAction(
                PlaybackStateCompat.CustomAction.Builder(
                    ACTION_FAVORITE,
                    favoriteTitle,
                    favoriteIcon
                ).build()
            )
        }

        mediaSession.setPlaybackState(stateBuilder.build())
    }

    private fun buildNotification(): Notification {
        updateMediaSessionMetadata()
        updatePlaybackState()

        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
            intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val albumArt: Bitmap? = currentAlbumArtPath?.let { path ->
            try { BitmapFactory.decodeFile(path) } catch (e: Exception) { null }
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText(currentArtist)
            .setSubText("${formatTime(currentPosition)} / ${formatTime(currentDuration)}")
            .setSmallIcon(R.drawable.ic_notification)
            .setLargeIcon(albumArt)
            .setContentIntent(contentIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setOngoing(true)

        // Android 13+ derives buttons from PlaybackState custom actions
        // Android 12 and below use notification actions
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // For Android 13+: Only add core playback controls
            // Custom actions (shuffle/favorite) are handled via PlaybackState
            val playPauseIntent = pendingBroadcast(100, ACTION_PLAY_PAUSE)
            val prevIntent = pendingBroadcast(101, ACTION_PREVIOUS)
            val nextIntent = pendingBroadcast(102, ACTION_NEXT)
            
            val playPauseIcon = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
            val playPauseText = if (isPlaying) "Pause" else "Play"

            builder
                .addAction(R.drawable.ic_previous, "Previous", prevIntent)
                .addAction(playPauseIcon, playPauseText, playPauseIntent)
                .addAction(R.drawable.ic_next, "Next", nextIntent)
                .setStyle(
                    MediaNotificationCompat.MediaStyle()
                        .setMediaSession(mediaSession.sessionToken)
                        .setShowActionsInCompactView(0, 1, 2)
                        .setShowCancelButton(true)
                )
        } else {
            // For Android 12 and below: Use traditional notification actions
            val playPauseIntent = pendingBroadcast(100, ACTION_PLAY_PAUSE)
            val prevIntent = pendingBroadcast(101, ACTION_PREVIOUS)
            val nextIntent = pendingBroadcast(102, ACTION_NEXT)
            val favoriteIntent = pendingBroadcast(103, ACTION_FAVORITE)
            val shuffleIntent = pendingBroadcast(104, ACTION_SHUFFLE)

            val playPauseIcon = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
            val playPauseText = if (isPlaying) "Pause" else "Play"
            val favoriteIcon = if (isFavorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border
            val favoriteText = if (isFavorite) "Unfavorite" else "Favorite"
            val shuffleIcon = if (isShuffleMode) R.drawable.ic_shuffle_on else R.drawable.ic_shuffle
            val shuffleText = if (isShuffleMode) "Shuffle On" else "Shuffle Off"

            builder
                .addAction(R.drawable.ic_previous, "Previous", prevIntent)
                .addAction(playPauseIcon, playPauseText, playPauseIntent)
                .addAction(R.drawable.ic_next, "Next", nextIntent)
                .addAction(shuffleIcon, shuffleText, shuffleIntent)
                .addAction(favoriteIcon, favoriteText, favoriteIntent)
                .setStyle(
                    MediaNotificationCompat.MediaStyle()
                        .setMediaSession(mediaSession.sessionToken)
                        .setShowActionsInCompactView(0, 1, 2)
                        .setShowCancelButton(true)
                )
        }

        // Progress bar only needed for Android 9 and below
        // Android 10+ MediaStyle renders it automatically from PlaybackState
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && currentDuration > 0) {
            val progress = ((currentPosition.toFloat() / currentDuration.toFloat()) * 100).toInt()
            builder.setProgress(100, progress, false)
        }

        return builder.build()
    }

    /** Helper to create a broadcast PendingIntent with CANCEL_CURRENT to avoid stale caches. */
    private fun pendingBroadcast(requestCode: Int, action: String): PendingIntent =
        PendingIntent.getBroadcast(
            this,
            requestCode,
            Intent(action).apply { setPackage(packageName) },
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun formatTime(millis: Long): String {
        val seconds = (millis / 1000).toInt()
        return String.format("%d:%02d", seconds / 60, seconds % 60)
    }

    fun updateNotification(
        title: String?, artist: String?, albumArtPath: String?,
        playing: Boolean?, duration: Long?, position: Long?,
        shuffle: Boolean?, favorite: Boolean?
    ) {
        title?.let { currentTitle = it }
        artist?.let { currentArtist = it }
        albumArtPath?.let { currentAlbumArtPath = it }
        playing?.let { isPlaying = it }
        duration?.let { currentDuration = it }
        position?.let { currentPosition = it }
        shuffle?.let { isShuffleMode = it }
        favorite?.let { isFavorite = it }

        val notification = buildNotification()
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun sendCommandToFlutter(command: String, args: Map<String, Any>? = null) {
        android.os.Handler(mainLooper).post {
            try {
                if (methodChannel == null) {
                    android.util.Log.w("MusicNotification", "Method channel null, reconnecting…")
                    FlutterEngineCache.getInstance().get("main_engine")?.let { engine ->
                        methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
                        android.util.Log.d("MusicNotification", "Method channel reconnected")
                    } ?: android.util.Log.e("MusicNotification", "Flutter engine not in cache")
                }

                android.util.Log.d("MusicNotification", "→ Flutter: $command")
                methodChannel?.invokeMethod(command, args, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        android.util.Log.d("MusicNotification", "✓ $command")
                    }
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        android.util.Log.e("MusicNotification", "✗ $command: $errorCode – $errorMessage")
                    }
                    override fun notImplemented() {
                        android.util.Log.e("MusicNotification", "✗ $command: not implemented")
                    }
                })
            } catch (e: Exception) {
                android.util.Log.e("MusicNotification", "Failed to send $command: ${e.message}", e)
            }
        }
    }
}
