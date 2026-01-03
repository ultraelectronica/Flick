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
        
        private const val PLAYER_CHANNEL = "com.ultraelectronica.flick/player"
    }
    
    private lateinit var mediaSession: MediaSessionCompat
    private lateinit var notificationManager: NotificationManager
    private var methodChannel: MethodChannel? = null
    
    private var currentTitle: String = "Unknown"
    private var currentArtist: String = "Unknown Artist"
    private var currentAlbumArtPath: String? = null
    private var isPlaying: Boolean = false
    
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
            currentTitle = it.getStringExtra("title") ?: "Unknown"
            currentArtist = it.getStringExtra("artist") ?: "Unknown Artist"
            currentAlbumArtPath = it.getStringExtra("albumArtPath")
            isPlaying = it.getBooleanExtra("isPlaying", true)
        }
        
        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        
        return START_NOT_STICKY
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
                override fun onPlay() {
                    sendCommandToFlutter("play")
                }
                
                override fun onPause() {
                    sendCommandToFlutter("pause")
                }
                
                override fun onSkipToNext() {
                    sendCommandToFlutter("next")
                }
                
                override fun onSkipToPrevious() {
                    sendCommandToFlutter("previous")
                }
                
                override fun onStop() {
                    sendCommandToFlutter("stop")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                
                override fun onSeekTo(pos: Long) {
                    sendCommandToFlutter("seek", mapOf("position" to pos))
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
        
        val playbackState = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                PlaybackStateCompat.ACTION_PAUSE or
                PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                PlaybackStateCompat.ACTION_STOP or
                PlaybackStateCompat.ACTION_SEEK_TO
            )
            .setState(state, PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN, 1.0f)
            .build()
        
        mediaSession.setPlaybackState(playbackState)
    }
    
    private fun buildNotification(): Notification {
        updateMediaSessionMetadata()
        updatePlaybackState()
        
        // Intent to open the app
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
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
        
        val stopIntent = PendingIntent.getBroadcast(
            this, 4,
            Intent(ACTION_STOP),
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
        
        val playPauseIcon = if (isPlaying) {
            android.R.drawable.ic_media_pause
        } else {
            android.R.drawable.ic_media_play
        }
        
        val playPauseText = if (isPlaying) "Pause" else "Play"
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText(currentArtist)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setLargeIcon(albumArt)
            .setContentIntent(contentIntent)
            .setDeleteIntent(stopIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_media_previous, "Previous", prevIntent)
            .addAction(playPauseIcon, playPauseText, playPauseIntent)
            .addAction(android.R.drawable.ic_media_next, "Next", nextIntent)
            .setStyle(
                MediaNotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
                    .setShowCancelButton(true)
                    .setCancelButtonIntent(stopIntent)
            )
            .build()
    }
    
    fun updateNotification(title: String?, artist: String?, albumArtPath: String?, playing: Boolean?) {
        title?.let { currentTitle = it }
        artist?.let { currentArtist = it }
        albumArtPath?.let { currentAlbumArtPath = it }
        playing?.let { isPlaying = it }
        
        val notification = buildNotification()
        notificationManager.notify(NOTIFICATION_ID, notification)
    }
    
    private fun sendCommandToFlutter(command: String, args: Map<String, Any>? = null) {
        // Post to main thread to ensure method channel is called correctly
        android.os.Handler(mainLooper).post {
            try {
                methodChannel?.invokeMethod(command, args)
            } catch (e: Exception) {
                // Method channel not available
            }
        }
    }
}
