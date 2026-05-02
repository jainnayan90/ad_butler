/**
 * ChatScroll: owns scroll lifecycle for the chat message stream.
 *
 * - Auto-scrolls to bottom on new chunks/messages when the user is
 *   within 50px of the bottom (i.e. actively reading the tail).
 * - Preserves the viewport when older messages are prepended at the
 *   top of the stream (load-older pagination): captures scrollHeight
 *   in beforeUpdate and restores scrollTop in updated.
 */
export const ChatScroll = {
  AT_BOTTOM_THRESHOLD: 50,

  mounted() {
    this.atBottom = true
    this._prevScrollHeight = null
    this._prevScrollTop = null

    this.scrollToBottom()

    this.el.addEventListener("scroll", () => {
      const distanceFromBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.atBottom = distanceFromBottom <= ChatScroll.AT_BOTTOM_THRESHOLD
    })
  },

  beforeUpdate() {
    if (!this.atBottom) {
      this._prevScrollHeight = this.el.scrollHeight
      this._prevScrollTop = this.el.scrollTop
    }
  },

  updated() {
    if (this._prevScrollHeight !== null) {
      // History prepended at top — keep the user's viewport stable.
      const heightDelta = this.el.scrollHeight - this._prevScrollHeight
      this.el.scrollTop = this._prevScrollTop + heightDelta
      this._prevScrollHeight = null
      this._prevScrollTop = null
    } else if (this.atBottom) {
      this.scrollToBottom()
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}
