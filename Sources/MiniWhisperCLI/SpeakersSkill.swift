import Foundation

enum SpeakersSkill {
    static let text =
        """
        ---
        name: miniwhisper-speakers
        description: Runtime guidance for MiniWhisper speaker attribution covering who spoke when, RTTM output, and per-channel splitting.
        ---

        # MiniWhisper Speakers

        Load this when the request asks **who** spoke, not only what was said: speaker
        labels, per-turn transcripts, or an RTTM file.

        `diarize` does not transcribe. It labels time ranges. A speaker-labelled
        transcript needs two runs joined on timestamps.

        ## Choose the route first

        Two recordings that sound the same need different commands.

        - **One speaker per channel.** Some recordings capture each source on its own
          channel. Transcribe each channel separately and tag by channel. Attribution
          is exact by construction and no clustering is involved.
          ```bash
          miniwhispercli transcribe <audio> --channel 0 -o side-a.txt
          miniwhispercli transcribe <audio> --channel 1 -o side-b.txt
          ```
        - **Shared microphone.** All speakers land in the same signal. Use `diarize`,
          which clusters voices and can be wrong.
          ```bash
          miniwhispercli diarize <audio> -o speakers.rttm
          ```

        Default `--channel mix` averages all channels. Pass a channel index when
        each channel holds an independent source.

        If a channel holds more than one person, diarize that channel alone:
        `miniwhispercli diarize <audio> --channel 1 --speakers 2`.

        ## Speaker count

        Run without `--speakers` first. Set it only when the count is known from the
        recording, not guessed from the result.

        If the automatic run and a fixed-count run disagree, the audio is genuinely
        ambiguous. Report both answers. Do not force a count to make the output tidy.

        `--threshold` applies only when `--speakers` is not set; a fixed count
        overrides it. Lower values find more speakers. Stay inside 0.5-0.9.

        ## Join to a transcript

        ```bash
        miniwhispercli transcribe <audio> --timestamps word --format json -o words.json
        miniwhispercli diarize <audio> -o speakers.rttm
        ```

        `transcribe` defaults to Parakeet. Prefer it for the transcript you join
        against: it needs no voice-activity detection, so it neither loops on silence
        nor loses punctuation on long recordings.

        `--model whisper` transcribes words more accurately but is a poor fit for long
        audio here. Requesting word timestamps disables its VAD, and it then repeats
        itself across silent stretches; leaving VAD on can strip punctuation and merge
        many turns into one long segment. On short clips neither problem appears.

        RTTM is one `SPEAKER` line per segment, ten space-separated fields. Field 4 is
        the **onset** and field 5 is the **duration**, both in seconds. Field 5 is not
        an end time; adding the two gives the end.

        Assign one speaker per transcript segment by majority overlap.

        ## Keep the timelines aligned

        A clipped transcript and a full-file RTTM do not share a timeline. `--from`,
        `--to` and `--duration` shift the transcript's clock but not the RTTM's.
        Either transcribe the whole file, or clip the audio once and run both commands
        against the clip.

        ## Known limits

        - Overlapping speech is not separated. Output segments do not overlap, so
          simultaneous talk is attributed to one speaker.
        - A single microphone with three or more people is the hardest case and shows
          real bleed. Say so instead of presenting the output as exact.
        - Report the route used (channel split or diarization), the speaker count, and
          whether the count was automatic or fixed.

        ## Output contract

        RTTM goes to stdout, or to `-o <file>`. Progress, model loading, and the
        summary line go to stderr. Do not parse stderr as data.
        """
}
