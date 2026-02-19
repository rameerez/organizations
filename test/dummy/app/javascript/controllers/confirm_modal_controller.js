import { Controller } from "@hotwired/stimulus"

// Modal-based type-to-confirm controller
// Shows a modal when button is clicked, requires typing phrase to confirm
export default class extends Controller {
  static targets = ["modal", "input", "confirmButton", "form"]
  static values = {
    phrase: String,
    title: String,
    message: String
  }

  open(event) {
    event.preventDefault()
    this.modalTarget.classList.remove("hidden")
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.validate()
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  validate() {
    const isMatch = this.inputTarget.value.trim() === this.phraseValue

    if (isMatch) {
      this.confirmButtonTarget.disabled = false
      this.confirmButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    } else {
      this.confirmButtonTarget.disabled = true
      this.confirmButtonTarget.classList.add("opacity-50", "cursor-not-allowed")
    }
  }

  submit(event) {
    if (this.inputTarget.value.trim() !== this.phraseValue) {
      event.preventDefault()
    }
  }

  // Close on escape key
  closeOnEscape(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }

  // Close on backdrop click
  closeOnBackdrop(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }
}
