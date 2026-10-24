# frozen_string_literal: true

module Form6
  # Table B's two columns, from the configuration's typology. A plot is Others
  # in the category column even when the typology is commercial land: the form
  # only has Residential, Commercial, and Others.
  module Classification
    module_function

    def unit_type(typology)
      return if typology.nil?
      return "Plot" if plot?(typology)
      return "Shop" if shop?(typology)
      return "Apartment" if apartment?(typology)

      "Others"
    end

    def category_label(typology)
      return if typology.nil?
      return "Others" if plot?(typology)
      return "Residential" if typology.residential?
      return "Commercial" if typology.commercial?

      "Others"
    end

    def plot?(typology)
      typology.land? || text(typology).match?(/plot/i)
    end

    def shop?(typology)
      typology.commercial? && text(typology).match?(/shop|showroom/i)
    end

    # RK only as a unit. "Park" contains the letters rk and is not an apartment.
    def apartment?(typology)
      typology.residential? && text(typology).match?(/bhk|\d\s*rk|studio|penthouse/i)
    end

    def text(typology)
      "#{typology.name} #{typology.code}"
    end
    private_class_method :text
  end
end
