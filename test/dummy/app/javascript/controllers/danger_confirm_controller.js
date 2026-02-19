import { Controller } from "@hotwired/stimulus"

// Type-to-confirm controller for dangerous actions
// Requires user to type a specific phrase before enabling the action
export default class extends Controller {
  static targets = ["input", "submitButton", "memberList"]
  static values = {
    phrase: String // The phrase user must type to confirm
  }

  connect() {
    this.validate()
  }

  validate() {
    const inputValue = this.inputTarget.value.trim()
    const isMatch = inputValue === this.phraseValue

    if (isMatch) {
      // Enable submit button if it's a real button
      if (this.hasSubmitButtonTarget && this.submitButtonTarget.tagName !== "P") {
        this.submitButtonTarget.disabled = false
        this.submitButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
        this.submitButtonTarget.classList.add("hover:bg-red-500")
      }
      // Hide the hint text if submitButton is a <p> element
      if (this.hasSubmitButtonTarget && this.submitButtonTarget.tagName === "P") {
        this.submitButtonTarget.classList.add("hidden")
      }
      // Show member list
      if (this.hasMemberListTarget) {
        this.memberListTarget.classList.remove("hidden")
      }
    } else {
      // Disable submit button if it's a real button
      if (this.hasSubmitButtonTarget && this.submitButtonTarget.tagName !== "P") {
        this.submitButtonTarget.disabled = true
        this.submitButtonTarget.classList.add("opacity-50", "cursor-not-allowed")
        this.submitButtonTarget.classList.remove("hover:bg-red-500")
      }
      // Show the hint text if submitButton is a <p> element
      if (this.hasSubmitButtonTarget && this.submitButtonTarget.tagName === "P") {
        this.submitButtonTarget.classList.remove("hidden")
      }
      // Hide member list
      if (this.hasMemberListTarget) {
        this.memberListTarget.classList.add("hidden")
      }
    }
  }
}
