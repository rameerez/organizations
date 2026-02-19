import { Controller } from "@hotwired/stimulus"

// Transfer ownership modal with two-step confirmation:
// 1. Select new owner
// 2. Type org name to confirm
// 3. Click confirm button
export default class extends Controller {
  static targets = ["modal", "memberList", "confirmStep", "input", "confirmButton", "selectedName", "form"]
  static values = {
    phrase: String,
    selectedMemberId: String
  }

  open(event) {
    event.preventDefault()
    this.modalTarget.classList.remove("hidden")
    this.memberListTarget.classList.remove("hidden")
    this.confirmStepTarget.classList.add("hidden")
    this.selectedMemberIdValue = ""
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  selectMember(event) {
    event.preventDefault()
    const button = event.currentTarget
    const memberId = button.dataset.memberId
    const memberEmail = button.dataset.memberEmail

    this.selectedMemberIdValue = memberId
    this.selectedNameTarget.textContent = memberEmail

    // Update form action
    this.formTarget.action = this.formTarget.dataset.baseUrl.replace("MEMBER_ID", memberId)

    // Hide member list, show confirm step
    this.memberListTarget.classList.add("hidden")
    this.confirmStepTarget.classList.remove("hidden")
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.validate()
  }

  backToSelect() {
    this.memberListTarget.classList.remove("hidden")
    this.confirmStepTarget.classList.add("hidden")
    this.selectedMemberIdValue = ""
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

  closeOnEscape(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }

  closeOnBackdrop(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }
}
