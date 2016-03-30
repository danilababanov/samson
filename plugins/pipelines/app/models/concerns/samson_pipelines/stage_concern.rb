module SamsonPipelines::StageConcern
  require 'byebug'
  # Return true if any stages in the pipeline are marked production
  # make sure to check the no_code_deployed flag on the 
  # next deployment as well
  def production?
    super || next_stages.any? { |next_stage|  (next_stage.production? && !next_stage.no_code_deployed?) }
  end

  def next_stages
    Stage.find(next_stage_ids)
  end

  protected

  # Ensure we don't have a circular pipeline:
  #
  # potential race-condition if 2 stages are saved at same time:
  #   stageA saved with pipelines to stageB and stageC
  #   stageC saved with pipeline to stageA   => will validate if stageA above hasn't been written to DB yet
  def valid_pipeline?(origin_id = id)
    next_stage_ids.select!(&:presence)
    if next_stage_ids.any? { |next_id| next_id.to_i == origin_id.to_i }
      errors[:base] << "Stage #{name} causes a circular pipeline with this stage"
      return false
    end

    next_stages.each do |stage|
      unless stage.valid_pipeline?(origin_id)
        errors[:base] << "Stage #{stage.name} causes a circular pipeline with this stage"
        return false
      end
    end
    true
  end

  # Make sure that this stage isn't referenced by another stage in a pipeline.
  # This will stop soft_deletion of the stage.
  def verify_not_part_of_pipeline
    project.stages.each do |s|
      if s.next_stage_ids.include?(id)
        errors[:base] << "Stage #{name} is in a pipeline from #{s.name} and cannot be deleted"
        return false
      end
    end
  end
end
