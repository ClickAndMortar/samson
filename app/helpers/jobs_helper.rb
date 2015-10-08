module JobsHelper
  def job_page_title
    "#{@project.name} deploy (#{@job.status})"
  end

  def job_active?
    @job.active? && (JobExecution.active?(@job.id) || (JobExecution.queued?(@job.id) && JobExecution.enabled))
  end

  def can_create_job?
    current_user.is_super_admin? || current_user.is_admin?
  end
end
