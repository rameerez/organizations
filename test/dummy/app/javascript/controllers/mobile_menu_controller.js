import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["backdrop"]

  open() {
    this.backdropTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  close() {
    this.backdropTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }
}
