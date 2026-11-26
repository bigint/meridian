# Base for Meridian's components. Small helpers for composing Tailwind classes.
class ApplicationComponent < ViewComponent::Base
  # Components don't inherit the controller's default_form_builder, so forms
  # built inside one would lose Meridian's input styles.
  def default_form_builder = MeridianFormBuilder

  private
    def classes(*names)
      names.flatten.compact_blank.join(" ")
    end
end
