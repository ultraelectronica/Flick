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
import java.io.File

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
            when (intent?.action) {
                ACTION_PLAY_PAUSE -> sendCommandToFlutter("togglePlayPause")
                ACTION_NEXT -> sendCommandToFlutter("next")
                ACTION_PREVIOUS -> sendCommandToFlutter("previous")
                ACTION_STOP -> {
                    sendCommandToFlutter("stop")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                ACTION_SHUFFLE -> sendCommandToFlutter("toggleShuffle")
                ACTION_FAVORITE -> sendCommandToFlutter("toggleFavorite")
            }
        }
    }
    
    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
        setupMediaSession()
        
        // Register broadcast receiver for notification actions
        val filter = IntentFilter().apply {
            addAction(ACTION_PLAY_PAUSE)
            addAction(ACTION_NEXT)
            addAction(ACTION_PREVIOUS)
            addAction(ACTION_STOP)
            addAction(ACTION_SHUFFLE)
            addAction(ACTION_FAVORITE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(actionReceiver, filter)
        }
        
        // Get method channel from cached Flutter engine
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
                val durationValue = it.extras?.get("duration")
                currentDuration = when (durationValue) {
                    is Long -> durationValue
                    is Int -> durationValue.toLong()
                    is Number -> durationValue.toLong()
                    else -> it.getLongExtra("duration", 0)
                }
            }
            if (it.hasExtra("position")) {
                val positionValue = it.extras?.get("position")
                currentPosition = when (positionValue) {
                    is Long -> positionValue
                    is Int -> positionValue.toLong()
                    is Number -> positionValue.toLong()
                    else -> it.getLongExtra("position", 0)
                }
            }
            if (it.hasExtra("isShuffle")) isShuffleMode = it.getBooleanExtra("isShuffle", false)
            if (it.hasExtra("isFavorite")) isFavorite = it.getBooleanExtra("isFavorite", false)
        }
        
        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // ensure service keeps running
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
    
    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(actionReceiver)
        } catch (e: Exception) {
            // Receiver not registered
        }
        mediaSession.release()
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
                   when(action) {
                       ACTION_SHUFFLE -> sendCommandToFlutter("toggleShuffle")
                       ACTION_FAVORITE -> sendCommandToFlutter("toggleFavorite")
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
            } catch (e: Exception) {
                // Failed to load bitmap
            }
        }
        
        mediaSession.setMetadata(metadata.build())
    }
    
    private fun updatePlaybackState() {
        val state = if (isPlaying) {
            PlaybackStateCompat.STATE_PLAYING
        } else {
            PlaybackStateCompat.STATE_PAUSED
        }
        
        // Playback speed: 1.0f when playing, 0.0f when paused (for progress bar animation)
        val playbackSpeed = if (isPlaying) 1.0f else 0.0f
        
        // Set shuffle mode on MediaSession
        mediaSession.setShuffleMode(
            if (isShuffleMode) {
                PlaybackStateCompat.SHUFFLE_MODE_ALL
            } else {
                PlaybackStateCompat.SHUFFLE_MODE_NONE
            }
        )
        
        val playbackState = PlaybackStateCompat.Builder()
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
            .build()
        
        mediaSession.setPlaybackState(playbackState)
    }
    
    private fun buildNotification(): Notification {
        updateMediaSessionMetadata()
        updatePlaybackState()
        
        // Intent to open the app (bring to front, don't create new instance)
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
            intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        
        // Action intents
        val playPauseIntent = PendingIntent.getBroadcast(
            this, 1,
            Intent(ACTION_PLAY_PAUSE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val prevIntent = PendingIntent.getBroadcast(
            this, 2,
            Intent(ACTION_PREVIOUS),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val nextIntent = PendingIntent.getBroadcast(
            this, 3,
            Intent(ACTION_NEXT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val shuffleIntent = PendingIntent.getBroadcast(
            this, 5,
            Intent(ACTION_SHUFFLE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val favoriteIntent = PendingIntent.getBroadcast(
            this, 6,
            Intent(ACTION_FAVORITE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        
        // Load album art
        val albumArt: Bitmap? = currentAlbumArtPath?.let { path ->
            try {
                BitmapFactory.decodeFile(path)
            } catch (e: Exception) {
                null
            }
        }
        
        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseText = if (isPlaying) "Pause" else "Play"
        
        // Shuffle & Favorite Icons
        val shuffleIcon = if(isShuffleMode) R.drawable.ic_shuffle_on else R.drawable.ic_shuffle
        val shuffleText = if(isShuffleMode) "Shuffle On" else "Shuffle Off"
        
        val favoriteIcon = if(isFavorite) android.R.drawable.btn_star_big_on else android.R.drawable.btn_star_big_off
        val favoriteText = if(isFavorite) "Unfavorite" else "Favorite"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText(currentArtist)
            .setSmallIcon(R.drawable.ic_notification)
            .setLargeIcon(albumArt)
            .setContentIntent(contentIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(isPlaying)
            // Actions: Shuffle, Prev, Play/Pause, Next, Favorite
            .addAction(shuffleIcon, shuffleText, shuffleIntent)
            .addAction(android.R.drawable.ic_media_previous, "Previous", prevIntent)
            .addAction(playPauseIcon, playPauseText, playPauseIntent)
            .addAction(android.R.drawable.ic_media_next, "Next", nextIntent)
            .addAction(favoriteIcon, favoriteText, favoriteIntent)
            .setStyle(
                MediaNotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    // Compact view: Shuffle (0), Play/Pause (2), Next (3)
                    .setShowActionsInCompactView(0, 2, 3)
                    .setShowCancelButton(true)
            )
            .build()
    }
    
    fun updateNotification(title: String?, artist: String?, albumArtPath: String?, playing: Boolean?, duration: Long?, position: Long?, shuffle: Boolean?, favorite: Boolean?) {
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
                methodChannel?.invokeMethod(command, args)
            } catch (e: Exception) {
            }
        }
    }
}
