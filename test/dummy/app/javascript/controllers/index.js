// Import and register all your controllers from the importmap via controllers/**/*_controller
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)

// Import and register TailwindCSS Stimulus Components
import { Alert } from "tailwindcss-stimulus-components"
application.register("alert", Alert)
